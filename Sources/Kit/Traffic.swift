import Foundation

/// Download and upload speed of the cloud PC, in MB/s.
public struct TrafficRate: Equatable, Sendable {
    public var downloadMBps: Double
    public var uploadMBps: Double
    public init(downloadMBps: Double = 0, uploadMBps: Double = 0) {
        self.downloadMBps = downloadMBps; self.uploadMBps = uploadMBps
    }
}

/// Turns the cloud PC's running byte counters (`netin`, `netout` in the VM status) into speeds, the way the
/// dashboard does: the change in each counter between two polls, over the seconds between them, in MB/s.
public struct TrafficMeter: Sendable {
    private var last: (netin: Double, netout: Double, at: Date)?
    public private(set) var rate = TrafficRate()

    public init() {}

    public mutating func record(netin: Double, netout: Double, at now: Date = .now) {
        defer { last = (netin, netout, now) }
        guard let last else { return }
        let seconds = now.timeIntervalSince(last.at)
        guard seconds > 0 else { return }
        // A counter that went down (the PC restarted) reads as no traffic, never as a negative speed
        rate = TrafficRate(downloadMBps: max(0, (netin - last.netin) / 1_048_576 / seconds),
                           uploadMBps: max(0, (netout - last.netout) / 1_048_576 / seconds))
    }

    /// Forgets the last sample (the cloud PC stopped), so the next reading doesn't compare against an old one.
    public mutating func reset() {
        last = nil
        rate = TrafficRate()
    }

    /// "1.4 GB", "230 MB": the data the cloud PC has moved since it started.
    public static func text(bytes: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(0, bytes)), countStyle: .binary)
    }
}
