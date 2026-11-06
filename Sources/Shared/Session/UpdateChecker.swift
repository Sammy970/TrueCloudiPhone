import Foundation
#if canImport(TrueCloudKit)
import TrueCloudKit
#endif

/// Tells the user when a newer version of this app is out on GitHub.
///
/// Checks at launch, every six hours while the app is open, and right away when TrueCloud starts refusing the
/// app (that's when a fixed version is most likely to be waiting). "Later" hides a version until the next launch.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    /// A release newer than this build, or nil.
    @Published private(set) var available: AppRelease?
    @Published private(set) var dismissed = false
    @Published private(set) var isChecking = false

    private let client = UpdateClient(repository: Config.githubRepository)
    private var loopTask: Task<Void, Never>?
    private var lastCheck: Date?
    private static let interval: TimeInterval = 6 * 60 * 60

    var shouldShow: Bool { available != nil && !dismissed }

    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(for: .seconds(Self.interval))
            }
        }
    }

    /// Checks now unless it checked in the last `minAge` seconds (GitHub allows 60 unauthenticated calls an hour).
    func check(minAge: TimeInterval = 60) async {
        if let lastCheck, Date.now.timeIntervalSince(lastCheck) < minAge { return }
        lastCheck = .now
        isChecking = true
        defer { isChecking = false }
        do {
            guard let release = try await client.latest() else { return }
            let newer = AppVersion.isNewer(release.version, than: Config.appVersion)
            if newer, available?.version != release.version {
                Log.info("[update] version \(release.version) is available (this is \(Config.appVersion))")
                dismissed = false
            }
            available = newer ? release : nil
        } catch {
            Log.info("[update] couldn't check for updates: \(error.localizedDescription)")
        }
    }

    func dismiss() { dismissed = true }

    #if DEBUG
    func preview(_ version: String) {
        available = AppRelease(version: version, pageURL: Config.releasesURL)
        dismissed = false
    }
    #endif
}
