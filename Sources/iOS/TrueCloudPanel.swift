import Combine
import SwiftUI
import UIKit
#if canImport(TrueCloudKit)
import TrueCloudKit
#endif

extension Notification.Name {
    /// Posted by MainFrameViewController when Moonlight starts pairing; userInfo["pin"].
    static let trueCloudPairingPIN = Notification.Name("TrueCloudPairingPIN")
    /// Posted by MainFrameViewController when Moonlight's pairing succeeded or failed.
    static let trueCloudPairingEnded = Notification.Name("TrueCloudPairingEnded")
}

/// Entry points used from Objective-C (`NSClassFromString(@"TrueCloudPanel")`).
@objc(TrueCloudPanel)
final class TrueCloudPanel: NSObject {
    /// Cloud PC address left by Play for MainFrameViewController to connect to once the panel closes.
    @MainActor static var pendingConnectAddress: String?

    @objc @MainActor static func makeViewController() -> UIViewController {
        let store = TrueCloudStore.shared
        let controller = PanelHostingController(rootView: AnyView(TrueCloudRootView(store: store).environmentObject(store.auth)))
        controller.modalPresentationStyle = .fullScreen
        // Switch to portrait before presenting: UIKit checks orientations at presentation time
        // and aborts if the app's mask and the controller's share none.
        store.panelVisible = true
        return controller
    }

    /// Read by AppDelegate's supportedInterfaceOrientationsForWindow.
    @objc @MainActor static var orientationMask: NSNumber {
        let store = TrueCloudStore.shared
        let mask: UIInterfaceOrientationMask = store.panelVisible && !store.controlsEditorOpen ? .portrait : .landscape
        return NSNumber(value: mask.rawValue)
    }

    /// Rotates the window to match `orientationMask` right away.
    @MainActor static func applyOrientation() {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        for window in scene.windows {
            var controller = window.rootViewController
            while let current = controller {
                current.setNeedsUpdateOfSupportedInterfaceOrientations()
                controller = current.presentedViewController
            }
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: UIInterfaceOrientationMask(rawValue: orientationMask.uintValue)))
    }

    /// Opens the full-screen editor for the on-screen gamepad's layout over whatever is on screen.
    @MainActor static func presentControlsEditor(preview: OSCEditorViewController.Preview = .none, bright: Bool = false) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              var top = scene.windows.first(where: \.isKeyWindow)?.rootViewController ?? scene.windows.first?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        let store = TrueCloudStore.shared
        let editor = OSCEditorViewController(preview: preview, bright: bright)
        editor.onClose = {
            store.controlsEditorOpen = false
            applyOrientation()
        }
        // The editor is landscape, so the app's mask has to allow it before it appears.
        store.controlsEditorOpen = true
        applyOrientation()
        top.present(editor, animated: true)
    }

    @objc @MainActor static func takePendingConnectAddress() -> String? {
        defer { pendingConnectAddress = nil }
        return pendingConnectAddress
    }
}

/// Hosts the panel in portrait and switches the app back to landscape when it closes.
/// It accepts any orientation itself, so the app-wide mask (`orientationMask`) alone decides
/// and the two can never end up with nothing in common.
private final class PanelHostingController: UIHostingController<AnyView> {
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Back in TrueCloud: the stream (and its overlay) is over.
        StreamOverlayWindow.shared.end()
        TrueCloudStore.shared.session.endExternalStream()
        TrueCloudStore.shared.panelVisible = true
        TrueCloudPanel.applyOrientation()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        TrueCloudStore.shared.panelVisible = false
        TrueCloudPanel.applyOrientation()
    }
}

/// Owns login and the cloud-PC session for the life of the app, so the session keeps running
/// while the panel is dismissed and Moonlight is streaming.
@MainActor
final class TrueCloudStore: ObservableObject {
    static let shared = TrueCloudStore()

    let auth = AuthStore()
    let session: SessionService
    /// True while the panel is on screen; otherwise session notices are shown over Moonlight.
    /// Starts true so the app launches in portrait straight into TrueCloud.
    var panelVisible = true
    /// True while the on-screen controls editor is open over the panel; it needs landscape.
    var controlsEditorOpen = false
    private var noticeSubscription: AnyCancellable?
    private var authSubscription: AnyCancellable?
    private var pinTask: Task<Void, Never>?

    private init() {
        session = SessionService(auth: auth)
        noticeSubscription = session.$notice.compactMap { $0 }.sink { [weak self] notice in
            Log.info("[panel] notice: \(notice.title) — \(notice.message)")
            guard let self, !panelVisible else { return }
            Self.presentOverMoonlight(notice)
        }
        // Polling runs while signed in.
        authSubscription = auth.$state.removeDuplicates().sink { [weak self] state in
            guard let self else { return }
            #if DEBUG
            if ProcessInfo.processInfo.environment["TRUECLOUD_PREVIEW"] != nil { return }
            #endif
            if state == .loggedIn { session.startPolling() } else { session.detach() }
        }
        NotificationCenter.default.addObserver(forName: .trueCloudPairingPIN, object: nil, queue: .main) { note in
            guard let pin = note.userInfo?["pin"] as? String else { return }
            Task { @MainActor in TrueCloudStore.shared.submitPairingPIN(pin) }
        }
        NotificationCenter.default.addObserver(forName: .trueCloudPairingEnded, object: nil, queue: .main) { _ in
            Task { @MainActor in TrueCloudStore.shared.pinTask?.cancel() }
        }
        if !startPreview() { Task { await auth.restore() } }
    }

    /// Debug builds only. Launch with `TRUECLOUD_PREVIEW=login` or `home:<phase>[:settings|network|controllers|about|sample]`
    /// to show a state with a sample account (no Keychain, no network), `TRUECLOUD_APPEARANCE=light|dark`, and
    /// `TRUECLOUD_SNAPSHOT=<name>` to save the screen to Documents/<name>.png a few seconds after launch.
    private func startPreview() -> Bool {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        guard let value = env["TRUECLOUD_PREVIEW"] else { return false }
        auth.previewSignIn(value == "login" ? nil : Self.sampleProfile)
        let phases: [String: SessionService.Phase] = [
            "checking": .checking, "idle": .idle, "starting": .starting, "booting": .booting,
            "ready": .ready, "pairing": .pairing, "streaming": .streaming, "shutting": .shuttingDown,
        ]
        if value.hasPrefix("home:"), let name = value.dropFirst(5).split(separator: ":").first, let phase = phases[String(name)] {
            session.previewPhase(phase, status: VmStatus(status: "running", uptime: 74, hasIP: true))
        }
        // `controls` opens the on-screen controls editor; add `:selected`, `:play` (controls lit as if held) or
        // `:bright` (day scene). `controls:selftest` runs the input-logic checks and logs the results.
        if value.hasPrefix("controls") {
            let options = Set(value.split(separator: ":").dropFirst().map(String.init))
            if options.contains("selftest") {
                OSCSelfTest.run()
            } else {
                let preview: OSCEditorViewController.Preview = options.contains("play") ? .playing : options.contains("selected") ? .selected : .none
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.5))
                    TrueCloudPanel.presentControlsEditor(preview: preview, bright: options.contains("bright"))
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let style: UIUserInterfaceStyle = env["TRUECLOUD_APPEARANCE"] == "light" ? .light : env["TRUECLOUD_APPEARANCE"] == "dark" ? .dark : .unspecified
            Self.keyWindow?.overrideUserInterfaceStyle = style
        }
        if let name = env["TRUECLOUD_SNAPSHOT"] {
            let delay = Double(env["TRUECLOUD_SNAPSHOT_DELAY"] ?? "") ?? 4
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let window = Self.keyWindow else { return }
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                try? image.pngData()?.write(to: docs.appendingPathComponent("\(name).png"))
                Log.info("[preview] saved \(name).png")
            }
        }
        return true
        #else
        return false
        #endif
    }

    #if DEBUG
    static let sampleProfile = RigProfile(
        uid: "preview", displayName: "Samyak Jain", node: "node1", vmid: 100, moonlightHost: "moonlight-a2.truecloud.in",
        currentPlan: "Pro", hoursRemaining: 3.95, planHours: 6, dailyLimitHours: 4, subscription: true, hasPairedBefore: true,
        expiration: .now.addingTimeInterval(12 * 86_400))
    #endif

    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
    }

    /// Play: leaves the address for MainFrameViewController, which adds the host, pairs and starts "Desktop".
    /// Returns the address Moonlight will connect to.
    func prepareConnection() throws -> String {
        guard let profile = auth.profile else { throw TCError.sessionExpired }
        let address = session.endpoint.streamAddress(for: profile)
        session.beginExternalStream()
        return address
    }

    /// Moonlight shows a PIN and waits for the host to receive it. TrueCloud's dashboard hands it to Sunshine:
    /// keep sending until pairing ends (Sunshine ignores a PIN that arrives before the pair request).
    private func submitPairingPIN(_ pin: String) {
        guard session.phase != .idle else { return }
        Log.info("[panel] Moonlight is pairing, session phase \(session.phase)")
        pinTask?.cancel()
        pinTask = Task { [session] in
            // Moonlight's pair request starts right after it shows the PIN; the first try waits a little for it.
            try? await Task.sleep(for: .seconds(3))
            let deadline = Date.now.addingTimeInterval(120)
            while !Task.isCancelled, Date.now < deadline {
                if await session.submitPairingPIN(pin) { return }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private static func presentOverMoonlight(_ notice: SessionService.Notice) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first { $0.isKeyWindow }?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        let alert = UIAlertController(title: notice.title, message: notice.message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        top?.present(alert, animated: true)
    }
}

struct TrueCloudRootView: View {
    @ObservedObject var store: TrueCloudStore
    @EnvironmentObject private var auth: AuthStore

    var body: some View {
        NavigationStack {
            ZStack {
                switch auth.state {
                case .restoring:
                    // The logo grows slightly and dissolves into the app, continuing the launch screen.
                    LaunchSplash()
                        .transition(.asymmetric(insertion: .identity, removal: .opacity.combined(with: .scale(scale: 1.12))))
                case .loggedOut:
                    // The aurora runs under a see-through bar on the sign-in screen.
                    LoginView()
                        .toolbarBackground(.hidden, for: .navigationBar)
                        .transition(.opacity)
                case .loggedIn:
                    TrueCloudHomeView(store: store)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.45), value: auth.state)
        }
        .tint(.tcAccent)
    }
}

/// Continues the launch screen (same colour, same logo, same place) while the saved sign-in loads.
private struct LaunchSplash: View {
    var body: some View {
        ZStack {
            Color("TrueCloudLaunchBackground").ignoresSafeArea()
            Image("TrueCloudLaunchLogo")
                .resizable()
                .frame(width: 171, height: 171)
            ProgressView()
                .offset(y: 120)
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}
