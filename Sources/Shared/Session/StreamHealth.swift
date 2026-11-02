import Foundation
#if canImport(TrueCloudKit)
import TrueCloudKit
#endif

/// Watches latency to the cloud PC during a stream and flags when it climbs well above that
/// stream's own baseline. A jump like that almost always means something on the cloud PC (a game
/// download, say) is filling its connection.
@MainActor
final class StreamHealth: ObservableObject {
    enum Status: Equatable { case measuring, good, congested }

    /// Median of the last few samples, in ms.
    @Published private(set) var latency: Double?
    @Published private(set) var status = Status.measuring
    /// Called once per congestion episode (and at most every two minutes) with the latency.
    var onCongestion: ((Double) -> Void)?

    /// The gateway's Moonlight port; a TCP handshake to it is one round trip.
    private static let probePort: UInt16 = 35450
    private var task: Task<Void, Never>?
    private var recent: [Double] = []
    private var baseline: Double?
    private var lastWarning: Date?

    func start(host address: String) {
        stop()
        let host = address.split(separator: ":").first.map(String.init) ?? address
        task = Task { [weak self] in
            while !Task.isCancelled {
                let ms = await NetworkCheck.handshakeTime(host: host, port: .init(rawValue: Self.probePort)!)
                if let ms { self?.record(ms) }
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        recent = []
        baseline = nil
        latency = nil
        status = .measuring
    }

    private func record(_ ms: Double) {
        recent.append(ms)
        if recent.count > 5 { recent.removeFirst() }
        let median = recent.sorted()[recent.count / 2]
        latency = median
        baseline = min(baseline ?? ms, ms)
        guard let baseline, recent.count >= 3 else { return }

        switch status {
        case .measuring, .good:
            if median > baseline + 35 && median > 75 {
                status = .congested
                if lastWarning.map({ Date().timeIntervalSince($0) > 120 }) ?? true {
                    lastWarning = .now
                    Log.info("[health] congested: \(Int(median)) ms (baseline \(Int(baseline)) ms)")
                    onCongestion?(median)
                }
            } else {
                status = .good
            }
        case .congested:
            if median < baseline + 20 { status = .good }
        }
    }
}

/// What the in-stream overlay shows: time left, session length, health and toasts.
/// The Mac shows it in a floating panel and the iPhone in a window over the stream.
@MainActor
final class StreamOverlayModel: ObservableObject {
    @Published var cardVisible = false
    @Published private(set) var toast: String?
    @Published private(set) var sessionStart: Date?
    let health = StreamHealth()

    /// Plan minutes left when the stream began; the overlay counts down from there.
    private var startMinutesLeft: Int?
    private var toastTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?

    var isActive: Bool { sessionStart != nil }

    func begin(host: String, profile: RigProfile?) {
        sessionStart = .now
        startMinutesLeft = profile?.minutesLeft
        health.onCongestion = { [weak self] ms in
            self?.showToast("Your cloud PC's connection is busy (\(Int(ms)) ms). Something on it, like a game download, may be using the bandwidth.")
        }
        health.start(host: host)

        // One reminder when plan time runs low.
        clockTask?.cancel()
        clockTask = Task { [weak self] in
            var warned = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self else { return }
                guard !warned, let left = minutesLeft(at: .now), left <= 10 else { continue }
                warned = true
                showToast("\(left) minute\(left == 1 ? "" : "s") of plan time left.")
            }
        }
    }

    func end() {
        health.stop()
        clockTask?.cancel()
        toastTask?.cancel()
        sessionStart = nil
        cardVisible = false
        toast = nil
    }

    func minutesLeft(at date: Date) -> Int? {
        guard let sessionStart, let startMinutesLeft else { return nil }
        return max(0, startMinutesLeft - Int(date.timeIntervalSince(sessionStart) / 60))
    }

    func showToast(_ text: String, for seconds: Double = 8) {
        toastTask?.cancel()
        toast = text
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
}
