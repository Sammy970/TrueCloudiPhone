import Foundation
#if canImport(TrueCloudKit)
import TrueCloudKit
#endif

/// Checks that TrueCloud still works the way this app expects, before anyone presses Start.
///
/// Every part of TrueCloud the app uses is checked:
/// - **Cloud PC controls** (truecloud.in): every Server Action the app calls still exists and takes the same
///   number of values, the admin switches still read the same, and a live status call answers.
/// - **Account** (Firestore): the profile still has the fields the app connects with.
/// - **Activity** and **Payments**: both still load and parse.
/// - A deliberate refusal (TrueCloud blocking apps) is reported as `blocked`, not as being offline.
///
/// When the controls check fails, Start, Shut Down and pairing are disabled with the reason, because pressing
/// them could do the wrong thing. Activity and Payments problems only affect those panes.
@MainActor
final class SiteHealth: ObservableObject {
    enum Area: String, CaseIterable, Identifiable {
        case controls = "Cloud PC controls"
        case account = "Account"
        case activity = "Activity"
        case payments = "Payments"
        var id: String { rawValue }
    }

    enum Result: Equatable {
        case ok
        /// TrueCloud changed something this app depends on: update needed.
        case changed([String])
        /// TrueCloud's website answered, but refused this app on purpose (its own words). Only an update can fix it.
        case blocked(String)
        /// Couldn't check (offline, TrueCloud down). Says nothing about compatibility.
        case unreachable(String)
    }

    @Published private(set) var results: [Area: Result] = [:]
    @Published private(set) var isChecking = false
    @Published private(set) var checkedAt: Date?

    private static let recheckInterval: TimeInterval = 10 * 60
    private var loopTask: Task<Void, Never>?

    /// Why the cloud PC controls must not be used right now, or nil.
    var controlsBlock: SessionService.Notice? {
        if let reason = blockedReason {
            return SessionService.Notice(
                title: "TrueCloud Is Blocking This App",
                message: "TrueCloud's website stopped accepting requests from this app, so it can't start, stop or pair your "
                    + "cloud PC right now. Check for an update, or use truecloud.in until then.\n\nTrueCloud said: \"\(reason)\"")
        }
        guard case .changed(let details) = results[.controls] else { return nil }
        return SessionService.Notice(
            title: "Update Needed",
            message: "TrueCloud changed its website, and this version of the app can't control your cloud PC safely. "
                + "Please update the app. Until then, start and stop it at truecloud.in.\n\n" + details.map { "• " + $0 }.joined(separator: "\n"))
    }

    /// TrueCloud's refusal, when any check was refused.
    var blockedReason: String? {
        for area in Area.allCases { if case .blocked(let reason) = results[area] { return reason } }
        return nil
    }

    var hasProblem: Bool {
        results.values.contains { if case .changed = $0 { true } else { false } }
    }

    /// Runs the checks now, then every ten minutes while the app is open.
    func start(auth: AuthStore) {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check(auth: auth)
                try? await Task.sleep(for: .seconds(Self.recheckInterval))
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    /// Re-checks the controls if the last check is older than `maxAge` (used right before Start).
    func ensureFresh(auth: AuthStore, maxAge: TimeInterval = 120) async {
        if let checkedAt, Date.now.timeIntervalSince(checkedAt) < maxAge { return }
        await check(auth: auth)
    }

    func check(auth: AuthStore) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false; checkedAt = .now }

        async let controls = checkControls(auth: auth)
        async let activity = checkFirestore { _ = try await auth.activityLog() }
        async let payments = checkFirestore { _ = try await auth.payments() }
        let account = checkAccount(auth.profile)
        let fresh: [Area: Result] = [.controls: await controls, .account: account,
                                     .activity: await activity, .payments: await payments]

        for area in Area.allCases where fresh[area] != results[area] {
            switch fresh[area] {
            case .ok: Log.info("[check] \(area.rawValue): OK")
            case .changed(let details): Log.info("[check] \(area.rawValue): CHANGED — " + details.joined(separator: "; "))
            case .blocked(let reason): Log.info("[check] \(area.rawValue): BLOCKED — \(reason)")
            case .unreachable(let reason): Log.info("[check] \(area.rawValue): couldn't check — \(reason)")
            case nil: break
            }
        }
        results = fresh
        // A refusal is usually fixed by a new version: look for one now rather than in a few hours.
        if blockedReason != nil { await UpdateChecker.shared.check() }
    }

    #if DEBUG
    func preview(_ results: [Area: Result]) { self.results = results }
    #endif

    // MARK: Checks

    private func checkControls(auth: AuthStore) async -> Result {
        let rig = auth.rig
        do {
            let ids = try await rig.resolver.refresh(force: false)
            var problems = SiteContract.problems(in: ids)
            problems += SiteContract.systemControlsProblems(try await rig.systemControlsJSON())
            if problems.isEmpty, let p = auth.profile {
                // End to end: the status call answers with a status.
                let token = try await auth.idToken()
                _ = try await rig.vmStatus(node: p.node, vmid: p.vmid, sunshineAddress: p.sunshineAddress, idToken: token)
            }
            return problems.isEmpty ? .ok : .changed(problems)
        } catch let error as TCError {
            switch error {
            case .actionsUnavailable: return .changed(["TrueCloud's site no longer lists the actions this app uses"])
            case .unexpectedResponse: return .changed(["TrueCloud's status answer is in a format this app doesn't know"])
            case .clientBlocked(let reason): return .blocked(reason)
            default: return .unreachable(error.localizedDescription)
            }
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }

    private func checkAccount(_ profile: RigProfile?) -> Result {
        guard let p = profile else { return .unreachable("account not loaded yet") }
        var problems: [String] = []
        if p.node.isEmpty { problems.append("your account no longer says which server your cloud PC is on") }
        if p.vmid <= 0 { problems.append("your account no longer has a cloud PC number") }
        if p.moonlightHost.isEmpty || p.sunshineAddress.isEmpty { problems.append("your account no longer has a Moonlight address") }
        return problems.isEmpty ? .ok : .changed(problems)
    }

    private func checkFirestore(_ load: () async throws -> Void) async -> Result {
        do {
            try await load()
            return .ok
        } catch TCError.unexpectedResponse {
            return .changed(["TrueCloud stores this in a format this app doesn't know"])
        } catch TCError.clientBlocked(let reason) {
            return .blocked(reason)
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }
}
