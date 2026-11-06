import SwiftUI
import UIKit

/// The small "gamepad on/off" button shown over the stream. It lives in a see-through window of its own
/// (above Moonlight, like the time-left pill) that takes touches on the button only; every other touch
/// falls through to the stream. Shown without becoming key, so Moonlight keeps keyboard and controller input.
/// The on-screen controls own it and switch themselves off and on when it's tapped.
@MainActor
final class GamepadToggleWindow {
    private let model = GamepadToggleModel()
    private var window: PassthroughWindow?
    private weak var ownerView: UIView?
    private var watchdog: Timer?
    private let onToggle: (Bool) -> Void

    /// Demo mode (the controls editor's "Try it"): the button only shows where it lives. Tapping it explains itself in a toast
    /// and changes nothing: the icon stays on and `onToggle` is never called.
    var isDemo: Bool {
        get { model.isDemo }
        set { model.isDemo = newValue; if newValue { model.isOn = true } }
    }
    /// Called after a tap in demo mode (for the self-test).
    var onDemoTap: (() -> Void)? {
        get { model.onDemoTap }
        set { model.onDemoTap = newValue }
    }

    init(scene: UIWindowScene, ownerView: UIView?, onToggle: @escaping (Bool) -> Void) {
        self.ownerView = ownerView
        self.onToggle = onToggle
        let window = PassthroughWindow(windowScene: scene)
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
        window.backgroundColor = .clear
        let controller = ToggleHostingController(rootView: AnyView(
            GamepadToggleRoot(model: model, window: window) { [weak self] on in self?.onToggle(on) }
                .tint(Color(OSCGlass.blue))
        ))
        controller.view.backgroundColor = .clear
        window.rootViewController = controller
        window.isHidden = true
        self.window = window
    }

    /// Whether the button is on screen.
    var isShown: Bool { window?.isHidden == false }

    func setShown(_ shown: Bool) {
        guard let window, window.isHidden == shown else { return }
        window.isHidden = !shown
        watchdog?.invalidate()
        watchdog = nil
        guard shown else { return }
        // If the stream goes away without telling us, don't leave the button floating over the app.
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.ownerView?.window == nil else { return }
                self.setShown(false)
            }
        }
    }

    /// Follows a change made elsewhere (e.g. the editor switching the gamepad back on), without calling back.
    func setOn(_ on: Bool) { model.isOn = on }

    func hide() { setShown(false) }

    /// What a tap does in demo mode, for the self-test.
    func simulateDemoTap() { model.demoTap() }
}

@MainActor
private final class GamepadToggleModel: ObservableObject {
    @Published var isOn = true
    @Published var toast: String?
    @Published var isDemo = false
    var onDemoTap: (() -> Void)?
    private var toastTask: Task<Void, Never>?

    func demoTap() {
        isOn = true
        flash("In a stream, this turns the on-screen controls off so you can use the mouse.", seconds: 2.8)
        onDemoTap?()
    }

    func flash(_ text: String, seconds: Double = 1.5) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
}

/// Keeps the stream's full-screen look: no status bar, home indicator auto-hidden, any landscape/portrait.
private final class ToggleHostingController: UIHostingController<AnyView> {
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
}

private struct GamepadToggleRoot: View {
    @ObservedObject var model: GamepadToggleModel
    let window: PassthroughWindow
    let onToggle: (Bool) -> Void
    @State private var dimmed = false
    @State private var dimTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Button(action: toggle) { icon }
                .buttonStyle(.plain)
                .opacity(dimmed ? 0.4 : 1)
                .animation(.easeInOut(duration: 0.5), value: dimmed)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { window.touchableRects = [$0.insetBy(dx: -6, dy: -6)] }
                .accessibilityLabel("On-screen gamepad")
                .accessibilityValue(model.isOn ? "On" : "Off")
                .accessibilityAddTraits(.isButton)
            if let toast = model.toast {
                Text(toast)
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 280, alignment: .trailing)
                    .glassCapsule()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        // In the editor's demo the Appearance button owns the top corner, so the demo button sits just to its left.
        .padding(.top, model.isDemo ? 6 : 8)
        .padding(.trailing, model.isDemo ? 66 : 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: model.toast)
        .sensoryFeedback(.impact(weight: .light), trigger: model.isOn)
        .onAppear(perform: scheduleDim)
    }

    private var icon: some View {
        ZStack {
            Image(systemName: model.isOn ? "gamecontroller.fill" : "gamecontroller")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(model.isOn ? Color(OSCGlass.blue) : Color.secondary)
            if !model.isOn {
                Capsule()
                    .fill(Color(red: 0.95, green: 0.36, blue: 0.36))
                    .frame(width: 28, height: 3)
                    .rotationEffect(.degrees(-45))
            }
        }
        .frame(width: 40, height: 40)
        .glassCapsule(tint: model.isOn ? Color(OSCGlass.blue).opacity(0.18) : nil)
        .contentShape(Circle())
    }

    private func toggle() {
        if model.isDemo {
            model.demoTap()
            scheduleDim()
            return
        }
        model.isOn.toggle()
        model.flash(model.isOn ? "On-screen controls on" : "On-screen controls off")
        onToggle(model.isOn)
        scheduleDim()
    }

    /// Fades to a faint hint so it doesn't sit on top of the game.
    private func scheduleDim() {
        dimmed = false
        dimTask?.cancel()
        dimTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            dimmed = true
        }
    }
}
