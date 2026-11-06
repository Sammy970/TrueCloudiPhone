import Foundation
#if canImport(TrueCloudKit)
import TrueCloudKit
#endif

/// Signs in with TrueCloud's Firebase project and keeps a fresh ID token. Only the refresh token is
/// stored (Keychain); the password is never kept.
@MainActor
final class AuthStore: ObservableObject {
    enum State { case restoring, loggedOut, loggedIn }

    @Published private(set) var state: State = .restoring
    @Published private(set) var profile: RigProfile?
    /// Shown on the login screen after a forced sign-out ("Your session expired").
    @Published var loginNotice: String?

    /// truecloud.in only answers a browser now, so its requests go through the hidden web view.
    let rig = WebBridge.makeRigAPI()
    private let firebase = FirebaseAuth()
    private let firestore = FirestoreClient()
    private var tokens: AuthTokens?
    private var refreshing: Task<AuthTokens, Error>?
    private static let refreshAccount = "refreshToken"

    #if DEBUG
    /// Screenshot mode: shows the signed-in UI with a fake profile, without touching the Keychain.
    func previewSignIn(_ profile: RigProfile?) {
        self.profile = profile
        state = profile == nil ? .loggedOut : .loggedIn
    }
    #endif

    func restore() async {
        guard let saved = Keychain.get(Self.refreshAccount) else { state = .loggedOut; return }
        do {
            adopt(try await firebase.refresh(refreshToken: saved))
            try await loadProfile()
            state = .loggedIn
        } catch TCError.sessionExpired {
            signOut(notice: "Your session expired. Please sign in again.")
        } catch {
            // Offline or a server hiccup at launch: keep the saved session and show the reason on the login screen.
            Log.info("[auth] restore failed: \(error.localizedDescription)")
            signOut(notice: error.localizedDescription, keepToken: true)
        }
    }

    func login(email: String, password: String) async throws {
        adopt(try await firebase.signIn(email: email, password: password))
        do { try await loadProfile() } catch { signOut(notice: nil); throw error }
        loginNotice = nil
        state = .loggedIn
    }

    func sendPasswordReset(email: String) async throws {
        try await firebase.sendPasswordReset(email: email)
    }

    func reloadProfile() async {
        guard let token = try? await idToken(), let uid = tokens?.uid else { return }
        if let fresh = try? await firestore.profile(uid: uid, idToken: token) { profile = fresh }
    }

    /// Tells TrueCloud this account has paired a Moonlight client, as the dashboard does once a PIN is accepted
    /// (its home page keeps showing the "get connected" guide until then). Once per account; a failure is only logged.
    func markPairedBefore() async {
        guard profile?.hasPairedBefore == false, let uid = tokens?.uid, let token = try? await idToken() else { return }
        do {
            try await firestore.markPairedBefore(uid: uid, idToken: token)
            profile?.hasPairedBefore = true
            Log.info("[auth] marked the account as paired")
        } catch {
            Log.info("[auth] couldn't mark the account as paired: \(error.localizedDescription)")
        }
    }

    /// The cloud PC's power-event log, as TrueCloud recorded it (newest first). Read the way the dashboard does,
    /// since TrueCloud stopped letting accounts read it from Firestore directly.
    func activityLog() async throws -> [ActivityEntry] {
        let token = try await idToken()
        guard let vmid = profile?.vmid else { throw TCError.profileMissing }
        return try await rig.vmLogs(vmid: vmid, idToken: token)
    }

    /// The account's payment history (newest first).
    func payments() async throws -> [PaymentRecord] {
        try await rig.transactions(idToken: try await idToken())
    }

    func logout() { signOut(notice: nil) }

    /// A valid ID token, refreshing it when it is about to expire (or when `force` is set).
    /// Throws `.sessionExpired` (and signs out) when the refresh token no longer works.
    func idToken(force: Bool = false) async throws -> String {
        if let tokens, !force, tokens.expiresAt.timeIntervalSinceNow > 90 { return tokens.idToken }
        guard let refresh = tokens?.refreshToken ?? Keychain.get(Self.refreshAccount) else {
            signOut(notice: TCError.sessionExpired.localizedDescription)
            throw TCError.sessionExpired
        }
        if let refreshing { return try await refreshing.value.idToken }
        let task = Task { try await firebase.refresh(refreshToken: refresh) }
        refreshing = task
        defer { refreshing = nil }
        do {
            let fresh = try await task.value
            adopt(fresh)
            return fresh.idToken
        } catch TCError.sessionExpired {
            signOut(notice: TCError.sessionExpired.localizedDescription)
            throw TCError.sessionExpired
        }
    }

    // MARK: Private

    private func adopt(_ tokens: AuthTokens) {
        self.tokens = tokens
        Keychain.set(tokens.refreshToken, for: Self.refreshAccount)
    }

    private func loadProfile() async throws {
        guard let tokens else { throw TCError.sessionExpired }
        profile = try await firestore.profile(uid: tokens.uid, idToken: tokens.idToken)
    }

    private func signOut(notice: String?, keepToken: Bool = false) {
        if !keepToken { Keychain.delete(Self.refreshAccount) }
        tokens = nil
        profile = nil
        loginNotice = notice
        state = .loggedOut
    }
}
