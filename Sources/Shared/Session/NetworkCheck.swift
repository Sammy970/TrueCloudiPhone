import Foundation
import Network
import os

/// Estimates how a stream would feel without starting the cloud PC.
///
/// Latency is the TCP round trip to the chosen TrueCloud gateway host (the address a stream connects
/// to). While the cloud PC is off its Moonlight port drops packets, so the check probes port 443: the
/// gateway answers it with an instant "connection refused", and that reply's timing is one round trip. Download
/// speed is measured against Cloudflare's public speed test: that's your internet connection.
@MainActor
final class NetworkCheck: ObservableObject {
    enum Stage: Equatable { case idle, latency, download, done, failed(String) }

    @Published private(set) var stage = Stage.idle
    /// Round-trip samples in milliseconds, in the order they were measured.
    @Published private(set) var samples: [Double] = []
    @Published private(set) var lost = 0
    @Published private(set) var downloadMbps: Double?
    /// Live download speed while the download runs.
    @Published private(set) var liveMbps: Double = 0

    static let sampleCount = 20
    /// Gateway host to probe (set from the selected endpoint).
    @Published var host = "moonlight-a2.truecloud.in"
    nonisolated static let latencyPort: NWEndpoint.Port = 443
    private static let downloadURL = URL(string: "https://speed.cloudflare.com/__down?bytes=50000000")!

    var isRunning: Bool { stage == .latency || stage == .download }

    // MARK: Results

    var medianLatency: Double? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        return sorted[sorted.count / 2]
    }

    /// Mean difference between consecutive samples, the usual definition of jitter.
    var jitter: Double? {
        guard samples.count > 1 else { return nil }
        let diffs = zip(samples, samples.dropFirst()).map { abs($1 - $0) }
        return diffs.reduce(0, +) / Double(diffs.count)
    }

    var lossPercent: Double {
        let total = samples.count + lost
        return total == 0 ? 0 : Double(lost) / Double(total) * 100
    }

    /// The bitrate (kbps) a stream at this resolution and frame rate needs, capped so it leaves
    /// headroom on the measured connection. A faster line doesn't make 1080p look better past
    /// what it needs; it only adds stutter risk on Wi-Fi.
    func suggestedBitrate(resolution: String, fps: String) -> Int? {
        guard let mbps = downloadMbps else { return nil }
        let at60: Double = ["720": 10, "1080": 20, "1440": 40, "2160": 50][resolution] ?? 20
        let factor: Double = fps == "30" ? 0.6 : fps == "120" ? 1.5 : 1
        let needed = at60 * factor
        let steps = [5, 10, 20, 30, 40, 50]
        let target = steps.first { Double($0) >= needed } ?? 50
        let affordable = steps.last { Double($0) <= mbps * 0.6 } ?? 5
        return min(target, affordable) * 1000
    }

    // MARK: Running

    func run() async {
        guard !isRunning else { return }
        samples = []
        lost = 0
        downloadMbps = nil
        liveMbps = 0

        stage = .latency
        let host = self.host
        _ = await Self.handshakeTime(host: host) // warm-up: DNS lookup and route setup
        for _ in 0..<Self.sampleCount {
            if let ms = await Self.handshakeTime(host: host) {
                samples.append(ms)
            } else {
                lost += 1
            }
            try? await Task.sleep(for: .milliseconds(120))
        }
        guard !samples.isEmpty else {
            stage = .failed("Couldn't reach \(host). Check your internet connection.")
            return
        }

        stage = .download
        downloadMbps = await Self.measureDownload { [weak self] mbps in
            Task { @MainActor in self?.liveMbps = mbps }
        }
        stage = .done
        Log.info("[network] latency \(medianLatency ?? 0) ms, jitter \(jitter ?? 0) ms, loss \(lost), download \(downloadMbps ?? 0) Mbps")
    }

    /// Time from starting a TCP connection to it being ready: one network round trip.
    nonisolated static func handshakeTime(host: String, port: NWEndpoint.Port = latencyPort) async -> Double? {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
            let start = DispatchTime.now()
            let finished = OSAllocatedUnfairLock(initialState: false)
            @Sendable func finish(_ value: Double?) {
                guard finished.withLock({ done in defer { done = true }; return !done }) else { return }
                connection.cancel()
                continuation.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
                case .waiting(let error), .failed(let error):
                    // "Connection refused" is the host answering: its timing is the round trip.
                    if case .posix(.ECONNREFUSED) = error {
                        finish(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
                    } else if case .failed = state {
                        finish(nil)
                    }
                case .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { finish(nil) }
        }
    }

    /// Downloads for up to 8 seconds and returns the average speed after the first half second
    /// (which is mostly connection setup and TCP ramp-up).
    private static func measureDownload(progress: @escaping @Sendable (Double) -> Void) async -> Double? {
        let meter = DownloadMeter(progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: meter, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return await meter.run(session.dataTask(with: downloadURL), limit: 8)
    }
}

/// Counts bytes as they arrive and reports throughput.
private final class DownloadMeter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var start: Date?
    private var bytesAfterWarmup = 0
    private var warmupEnd: Date?
    private var continuation: CheckedContinuation<Double?, Never>?

    init(progress: @escaping @Sendable (Double) -> Void) {
        self.progress = progress
    }

    func run(_ task: URLSessionDataTask, limit: TimeInterval) async -> Double? {
        await withCheckedContinuation { continuation in
            lock.withLock { self.continuation = continuation }
            task.resume()
            DispatchQueue.global().asyncAfter(deadline: .now() + limit) { [weak self] in
                task.cancel()
                self?.finish()
            }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let now = Date()
        if start == nil { start = now; warmupEnd = now.addingTimeInterval(0.5) }
        var mbps: Double?
        if let warmupEnd, now >= warmupEnd {
            bytesAfterWarmup += data.count
            let elapsed = now.timeIntervalSince(warmupEnd)
            if elapsed > 0.2 { mbps = Double(bytesAfterWarmup) * 8 / elapsed / 1_000_000 }
        }
        lock.unlock()
        if let mbps { progress(mbps) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish()
    }

    private func finish() {
        lock.lock()
        defer { lock.unlock() }
        guard let continuation else { return }
        self.continuation = nil
        guard let warmupEnd, bytesAfterWarmup > 0 else {
            continuation.resume(returning: nil)
            return
        }
        let elapsed = Date().timeIntervalSince(warmupEnd)
        continuation.resume(returning: elapsed > 0 ? Double(bytesAfterWarmup) * 8 / elapsed / 1_000_000 : nil)
    }
}
