import Foundation
#if canImport(TrueCloudKit)
import TrueCloudKit
#endif

/// Platform-specific part of a launch: pairing with and streaming from the cloud PC's Sunshine host.
/// macOS drives the Moonlight app's CLI.
@MainActor
protocol StreamDriver: AnyObject {
    /// Pairs if needed and streams until the stream ends. Call `session.markStreaming()`
    /// once pairing is done and `session.markPairing()` if it has to pair again.
    func run(host: String, settings: StreamSettings, session: SessionService) async throws
    /// Stops anything `run` started. Called when the session tears down.
    func stop()
}

/// Which TrueCloud gateway to stream through. Both reach the same rig on port 35450.
enum Endpoint: String, CaseIterable, Identifiable, Codable {
    case a2, a4
    var id: String { rawValue }
    var label: String { rawValue.uppercased() }

    /// "moonlight-a2.truecloud.in" for the rig's profile host, swapped to this gateway.
    func host(for profile: RigProfile) -> String {
        let base = profile.moonlightHost
        switch self {
        case .a2: return base.replacingOccurrences(of: "-a4.", with: "-a2.")
        case .a4: return base.replacingOccurrences(of: "-a2.", with: "-a4.")
        }
    }

    /// What Moonlight connects to.
    func streamAddress(for profile: RigProfile) -> String { "\(host(for: profile)):\(TCConstants.streamPort)" }

    private static let key = "endpoint"
    static func load() -> Endpoint { UserDefaults.standard.string(forKey: key).flatMap(Endpoint.init) ?? .a2 }
    func save() { UserDefaults.standard.set(rawValue, forKey: Self.key) }
}

/// Owns the cloud-PC state: polls the rig's status, starts / stops it, and (with a `StreamDriver`)
/// runs the stream.
@MainActor
final class SessionService: ObservableObject {
    enum Phase: Equatable {
        case checking       // first status poll in flight
        case idle           // powered off
        case starting       // power-on sent, VM booting
        case booting        // Windows is up, waiting for Sunshine
        case ready
        case pairing
        case streaming
        case shuttingDown

        var statusText: String {
            switch self {
            case .checking: "Checking your cloud PC…"
            case .idle: "Offline"
            case .starting: "Starting"
            case .booting: "Booting Sunshine"
            case .ready: "Ready"
            case .pairing: "Pairing with Moonlight…"
            case .streaming: "Streaming"
            case .shuttingDown: "Shutting down"
            }
        }

        var isBusy: Bool {
            switch self {
            case .checking, .starting, .booting, .pairing, .shuttingDown: true
            default: false
            }
        }
    }

    struct Notice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    @Published private(set) var phase: Phase = .checking
    @Published private(set) var status: VmStatus?
    @Published var notice: Notice?
    /// The address Moonlight is connected to while a stream runs (for the in-stream overlay).
    @Published private(set) var streamHost: String?
    @Published var endpoint = Endpoint.load() { didSet { endpoint.save() } }
    /// Seconds until the next start is allowed (the website enforces a 30 s cooldown).
    @Published private(set) var cooldown = 0

    private let auth: AuthStore
    private let driver: StreamDriver?
    private var rig: RigAPI { auth.rig }
    private var pollTask: Task<Void, Never>?
    private var launchTask: Task<Void, Never>?
    private var startedAt: Date?
    private var shutdownAt: Date?
    private var cooldownTask: Task<Void, Never>?

    /// How long a power-on may show "stopped" before we call it failed.
    private static let startGrace: TimeInterval = 120
    private static let shutdownGrace: TimeInterval = 180

    init(auth: AuthStore, driver: StreamDriver? = nil) {
        self.auth = auth
        self.driver = driver
    }

    var profile: RigProfile? { auth.profile }
    var lockMessage: String? {
        guard let lock = status?.lock, !lock.isEmpty else { return nil }
        return lock == "clone" ? "Your new cloud PC is being built. This takes a few minutes." : "Your cloud PC is busy (\(lock)). Try again shortly."
    }

    #if DEBUG
    /// Screenshot mode: forces a phase and optional status without touching the network.
    func previewPhase(_ phase: Phase, status: VmStatus? = nil) {
        stopPolling()
        self.phase = phase
        self.status = status
    }
    #endif

    // MARK: Polling

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await refreshStatus()
                try? await Task.sleep(for: .seconds(pollInterval))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Faster while something is changing, slower when idle or streaming.
    private var pollInterval: Double {
        switch phase {
        case .starting, .booting, .shuttingDown, .checking: 3
        case .ready, .pairing: 5
        case .idle: 10
        case .streaming: 15
        }
    }

    func refreshStatus() async {
        guard let p = profile else { return }
        do {
            let s = try await rig.vmStatus(node: p.node, vmid: p.vmid, sunshineAddress: p.sunshineAddress)
            status = s
            apply(s)
        } catch {
            Log.info("[session] status failed: \(error.localizedDescription)")
            if phase == .checking { phase = .idle }
        }
    }

    private func apply(_ s: VmStatus) {
        switch phase {
        case .pairing, .streaming:
            if s.isStopped {
                driver?.stop()
                streamHost = nil
                phase = .idle
                notice = Notice(title: "Cloud PC Stopped", message: "Your cloud PC powered off, so the stream ended.")
            }
        case .shuttingDown:
            if s.isStopped { phase = .idle; shutdownAt = nil }
            else if let at = shutdownAt, Date.now.timeIntervalSince(at) > Self.shutdownGrace { phase = s.isRunning ? .ready : .idle }
        default:
            if s.isRunning && s.isSunshineReady {
                startedAt = nil
                phase = .ready
            } else if s.isRunning {
                phase = s.hasIP ? .booting : .starting
            } else if let at = startedAt {
                if Date.now.timeIntervalSince(at) > Self.startGrace {
                    startedAt = nil
                    phase = .idle
                    notice = Notice(title: "Cloud PC Didn't Start", message: "The power-on command was sent but your cloud PC is still off. Check your plan time on truecloud.in, then try again.")
                } else {
                    phase = .starting
                }
            } else {
                phase = .idle
            }
        }
    }

    /// Leaves the screen or signs out: stops polling and any stream, but leaves the cloud PC as it is.
    func detach() {
        stopPolling()
        launchTask?.cancel()
        driver?.stop()
        streamHost = nil
    }

    // MARK: Controls

    func start() {
        guard phase == .idle, let p = profile else { return }
        guard p.subscription else {
            notice = Notice(title: "No Active Plan", message: "Your TrueCloud subscription isn't active. Renew it at truecloud.in.")
            return
        }
        guard p.hasEnoughTimeToStart else {
            notice = Notice(title: "Not Enough Time", message: "You need at least 3 minutes of plan time left to start. Upgrade or add time at truecloud.in.")
            return
        }
        guard cooldown == 0 else {
            notice = Notice(title: "Please Wait", message: "Wait \(cooldown)s between start attempts.")
            return
        }
        if lockMessage != nil { notice = Notice(title: "Cloud PC Busy", message: lockMessage ?? ""); return }
        phase = .starting
        startedAt = .now
        Task {
            do {
                try await withToken { try await self.rig.startVm(node: p.node, vmid: p.vmid, idToken: $0) }
                beginCooldown()
                await refreshStatus()
            } catch {
                startedAt = nil
                phase = .idle
                report("Couldn't Start", error)
            }
        }
    }

    /// Graceful shutdown. The stream (if any) ends first.
    func shutDown() {
        guard let p = profile else { return }
        perform("Couldn't Shut Down", to: .shuttingDown) {
            try await self.rig.shutdownVm(node: p.node, vmid: p.vmid, idToken: $0)
        }
    }

    func forceStop() {
        guard let p = profile else { return }
        perform("Couldn't Force Stop", to: .shuttingDown) {
            try await self.rig.stopVm(node: p.node, vmid: p.vmid, idToken: $0)
        }
    }

    func unpairAll() {
        guard let p = profile else { return }
        Task {
            do {
                try await withToken { try await self.rig.unpairAllDevices(sunshineAddress: p.sunshineAddress, idToken: $0) }
                notice = Notice(title: "Devices Unpaired", message: "Every paired device was removed. You'll be paired again the next time you press Play.")
            } catch {
                report("Couldn't Unpair", error)
            }
        }
    }

    private func perform(_ failureTitle: String, to target: Phase, _ action: @escaping (String) async throws -> Void) {
        let previous = phase
        launchTask?.cancel()
        driver?.stop()
        streamHost = nil
        phase = target
        shutdownAt = .now
        startedAt = nil
        Task {
            do {
                try await withToken(action)
                await refreshStatus()
            } catch {
                phase = previous == .shuttingDown ? .ready : previous
                shutdownAt = nil
                report(failureTitle, error)
            }
        }
    }

    // MARK: Streaming

    /// Hands off to the platform driver, which pairs first if Moonlight isn't paired yet.
    func play(settings: StreamSettings) {
        guard phase == .ready, let driver, let p = profile else { return }
        phase = .pairing
        let address = endpoint.streamAddress(for: p)
        launchTask = Task { [weak self] in
            guard let self else { return }
            streamHost = address
            do {
                try await driver.run(host: address, settings: settings, session: self)
            } catch is CancellationError {
            } catch {
                notice = Notice(title: "Stream Error", message: error.localizedDescription)
            }
            streamHost = nil
            if phase == .pairing || phase == .streaming { phase = .ready }
            await refreshStatus()
        }
    }

    /// iPhone: Moonlight (inside this app) pairs and streams; the panel is closed meanwhile.
    func beginExternalStream() {
        guard let p = profile else { return }
        streamHost = endpoint.streamAddress(for: p)
        phase = .streaming
    }

    /// iPhone: back in the panel after the stream.
    func endExternalStream() {
        guard streamHost != nil else { return }
        streamHost = nil
        if phase == .pairing || phase == .streaming { phase = .ready }
        Task { await refreshStatus() }
    }

    func markStreaming() { if phase == .pairing { phase = .streaming } }
    func markPairing() { if phase == .streaming { phase = .pairing } }

    /// Gives Sunshine the PIN Moonlight is showing. False if TrueCloud refused it (try again).
    func submitPairingPIN(_ pin: String) async -> Bool {
        guard let p = profile else { return false }
        do {
            try await withToken { try await self.rig.sendPin(sunshineAddress: p.sunshineAddress, pin: pin, idToken: $0) }
            Log.info("[pair] PIN accepted")
            return true
        } catch {
            Log.info("[pair] PIN not accepted: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: Helpers

    /// Runs `action` with a fresh ID token; on an authorization failure refreshes the token once and retries.
    private func withToken(_ action: (String) async throws -> Void) async throws {
        do {
            try await action(try await auth.idToken())
        } catch TCError.sessionExpired {
            try await action(try await auth.idToken(force: true))
        }
    }

    private func report(_ title: String, _ error: Error) {
        Log.info("[session] \(title): \(error.localizedDescription)")
        if let e = error as? TCError, e == .sessionExpired { return } // AuthStore already signed out with its own message
        notice = Notice(title: title, message: error.localizedDescription)
    }

    private func beginCooldown() {
        cooldown = 30
        cooldownTask?.cancel()
        cooldownTask = Task { [weak self] in
            while let self, cooldown > 0, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                cooldown -= 1
            }
        }
    }
}
