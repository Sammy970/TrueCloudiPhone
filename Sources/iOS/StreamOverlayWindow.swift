import SwiftUI
import UIKit
#if canImport(TrueCloudKit)
import TrueCloudKit
#endif

/// The in-stream overlay on iPhone: a see-through window above Moonlight with a small time-left
/// pill at the top. Tap the pill for the full card; busy-connection and low-time warnings drop in
/// below it. Every touch outside the pill and card goes straight through to the stream.
@MainActor
final class StreamOverlayWindow {
    static let shared = StreamOverlayWindow()

    let model = StreamOverlayModel()
    private var window: PassthroughWindow?

    func begin(host: String, profile: RigProfile?) {
        guard !model.isActive,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else { return }
        model.begin(host: host, profile: profile)
        let window = PassthroughWindow(windowScene: scene)
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
        window.backgroundColor = .clear
        let controller = OverlayHostingController(rootView: AnyView(
            StreamOverlayPhoneRoot(model: model, health: model.health, window: window).tint(.tcAccent)
        ))
        controller.view.backgroundColor = .clear
        window.rootViewController = controller
        // Shown without becoming key, so Moonlight keeps keyboard and controller input.
        window.isHidden = false
        self.window = window
    }

    func end() {
        guard model.isActive else { return }
        model.end()
        window?.isHidden = true
        window = nil
    }
}

/// Lets touches through everywhere except the overlay's own controls. SwiftUI's hosting view
/// claims every point, so the controls report their frames and only those are kept.
final class PassthroughWindow: UIWindow {
    var touchableRects: [CGRect] = []

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard touchableRects.contains(where: { $0.contains(point) }) else { return nil }
        return super.hitTest(point, with: event)
    }
}

/// Keeps the stream's full-screen look: no status bar, home indicator auto-hidden.
private final class OverlayHostingController: UIHostingController<AnyView> {
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
}

private struct StreamOverlayPhoneRoot: View {
    @ObservedObject var model: StreamOverlayModel
    @ObservedObject var health: StreamHealth
    let window: PassthroughWindow
    @State private var dimmed = false
    @State private var dimTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 10) {
            Button(action: toggleCard) { pill }
                .buttonStyle(.plain)
                .reportsTouchableFrame(to: window, id: 0)

            if model.cardVisible {
                Button(action: toggleCard) {
                    StreamOverlayCard(model: model, health: health, hint: "Tap to hide")
                }
                .buttonStyle(.plain)
                .reportsTouchableFrame(to: window, id: 1)
                .transition(.scale(scale: 0.9, anchor: .top).combined(with: .opacity))

                Button(action: editControls) {
                    Label("Edit controls", systemImage: "gamecontroller")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .glassCapsule()
                }
                .buttonStyle(.plain)
                .reportsTouchableFrame(to: window, id: 2)
                .transition(.scale(scale: 0.9, anchor: .top).combined(with: .opacity))
            }

            if let toast = model.toast {
                StreamToast(text: toast)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.top, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: model.cardVisible)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: model.toast)
        .onAppear(perform: scheduleDim)
        .onChange(of: model.cardVisible) { _, visible in
            if !visible { window.touchableRects = Array(window.touchableRects.prefix(1)) }
        }
        .sensoryFeedback(.warning, trigger: model.toast) { _, new in new != nil }
    }

    /// Time left and latency; fades to a faint hint so it doesn't sit on top of the game.
    private var pill: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 8) {
                Image(systemName: "timer")
                    .font(.caption.weight(.semibold))
                if let left = model.minutesLeft(at: context.date) {
                    Text(PlanUsage.duration(left))
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                LatencyBadge(health: health)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .glassCapsule()
        }
        .opacity(dimmed && !model.cardVisible && model.toast == nil ? 0.35 : 1)
        .animation(.easeInOut(duration: 0.6), value: dimmed)
    }

    private func toggleCard() {
        model.cardVisible.toggle()
        scheduleDim()
    }

    /// Opens the on-screen controls' layout editor over the stream.
    private func editControls() {
        model.cardVisible = false
        NotificationCenter.default.post(name: .trueCloudEditControls, object: nil)
    }

    private func scheduleDim() {
        dimmed = false
        dimTask?.cancel()
        dimTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            dimmed = true
        }
    }
}

private extension View {
    /// Tells the passthrough window where this control is, so it can receive touches.
    func reportsTouchableFrame(to window: PassthroughWindow, id: Int) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            var rects = window.touchableRects
            while rects.count <= id { rects.append(.zero) }
            rects[id] = frame
            window.touchableRects = rects
        }
    }
}
