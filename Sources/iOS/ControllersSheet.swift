import CoreHaptics
import GameController
import SwiftUI

/// Connected game controllers, as Apple's GameController framework sees them: the same framework Moonlight
/// on iPhone reads them through, so a controller listed here is one Moonlight can use.
@MainActor
final class GamepadMonitor: ObservableObject {
    struct Pad: Identifiable, Equatable {
        let id: ObjectIdentifier?
        var name: String
        var category: String
        var battery: Float?
        var charging = false
        var style: PadStyle
        var canVibrate: Bool
        var state = PadState()
    }

    @Published private(set) var pads: [Pad] = []

    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var preview = false
    private var hapticEngine: CHHapticEngine?

    init() {
        let center = NotificationCenter.default
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        refresh()
    }

    /// Live input, sixty times a second, while the controller check is open.
    func startLive() {
        guard !preview else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stopLive() {
        timer?.invalidate()
        timer = nil
    }

    /// Screenshot mode: a sample Xbox controller mid-press, without any hardware.
    func showPreview() {
        preview = true
        var state = PadState()
        state.pressed = [.a, .rightShoulder]
        state.leftStick = CGPoint(x: 0.55, y: 0.35)
        state.rightTrigger = 0.7
        pads = [Pad(id: nil, name: "Xbox Wireless Controller", category: "Xbox One", battery: 0.8,
                    style: .xbox, canVibrate: true, state: state)]
    }

    private func refresh() {
        guard !preview else { return }
        let list = GCController.controllers().filter { $0.extendedGamepad != nil }.map { controller in
            Pad(id: ObjectIdentifier(controller), name: controller.vendorName ?? "Controller",
                category: controller.productCategory,
                // Controllers that don't report battery read 0% with an unknown state; show nothing for those.
                battery: controller.battery.flatMap { $0.batteryState == .unknown ? nil : $0.batteryLevel },
                charging: controller.battery?.batteryState == .charging,
                style: PadStyle(controller), canVibrate: controller.haptics != nil,
                state: pads.first { $0.id == ObjectIdentifier(controller) }?.state ?? PadState())
        }
        if list != pads { pads = list }
        Log.info("[controllers] \(list.map { "\($0.name) (\($0.category))" })")
    }

    private func poll() {
        var updated = pads
        for (i, pad) in updated.enumerated() {
            guard let controller = GCController.controllers().first(where: { ObjectIdentifier($0) == pad.id }),
                  let gamepad = controller.extendedGamepad else { continue }
            updated[i].state = PadState(gamepad)
        }
        if updated != pads { pads = updated }
    }

    /// A short buzz on the controller, to check its motors.
    func vibrate(_ pad: Pad) {
        guard let controller = GCController.controllers().first(where: { ObjectIdentifier($0) == pad.id }),
              let engine = controller.haptics?.createEngine(withLocality: .default) else { return }
        do {
            try engine.start()
            let buzz = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
            ], relativeTime: 0, duration: 0.5)
            try engine.makePlayer(with: CHHapticPattern(events: [buzz], parameters: [])).start(atTime: 0)
            hapticEngine = engine
        } catch {
            Log.info("[controllers] vibration failed: \(error.localizedDescription)")
        }
    }
}

/// Check a controller before playing: a drawn controller that mirrors every press, the same check as the Mac
/// app's Controllers pane.
struct ControllersSheet: View {
    @ObservedObject var monitor: GamepadMonitor
    let done: () -> Void
    @State private var selected: ObjectIdentifier?

    private var pad: GamepadMonitor.Pad? {
        monitor.pads.first { $0.id == selected } ?? monitor.pads.first
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Press its buttons and move the sticks: everything that reaches your iPhone lights up here, so you know it'll work before you start the cloud PC.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if monitor.pads.count > 1 {
                        Picker("Controller", selection: Binding(get: { pad?.id }, set: { selected = $0 })) {
                            ForEach(monitor.pads) { Text($0.name).tag($0.id) }
                        }
                        .pickerStyle(.segmented)
                    }

                    if let pad {
                        card(pad)
                    } else {
                        empty
                    }
                }
                .padding(20)
            }
            .background { AuroraBackground(intensity: 0.35) }
            .navigationTitle("Controllers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: done) }
            }
        }
        .onAppear { monitor.startLive() }
        .onDisappear { monitor.stopLive() }
    }

    private func card(_ pad: GamepadMonitor.Pad) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Color.tcAccent.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(pad.name).font(.headline)
                    Text(details(pad)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .glassCapsule(tint: .green.opacity(0.15))
            }

            GamepadView(state: pad.state, style: pad.style)
                .frame(maxWidth: 420)
                .frame(maxWidth: .infinity)

            // The exact numbers, for checking stick drift and how far the triggers travel.
            HStack(spacing: 0) {
                value("Left stick", String(format: "%+.2f %+.2f", pad.state.leftStick.x, pad.state.leftStick.y))
                value("Right stick", String(format: "%+.2f %+.2f", pad.state.rightStick.x, pad.state.rightStick.y))
                value("Triggers", String(format: "%.2f %.2f", pad.state.leftTrigger, pad.state.rightTrigger))
            }
            .padding(.vertical, 10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            if pad.canVibrate {
                Button {
                    monitor.vibrate(pad)
                } label: {
                    Label("Test Vibration", systemImage: "waveform")
                }
                .secondaryGlassButton()
            }

            Text("Your iPhone recognises this controller, so Moonlight can send it to your cloud PC.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .glassSurface(cornerRadius: 22)
    }

    private func details(_ pad: GamepadMonitor.Pad) -> String {
        var parts = [pad.category]
        if let battery = pad.battery {
            parts.append("Battery \(Int((battery * 100).rounded()))%\(pad.charging ? ", charging" : "")")
        }
        return parts.joined(separator: " · ")
    }

    private func value(_ title: String, _ text: String) -> some View {
        VStack(spacing: 3) {
            Text(text).font(.system(.caption, design: .monospaced).weight(.medium))
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var empty: some View {
        VStack(spacing: 16) {
            GamepadView(state: PadState(), dimmed: true)
                .frame(maxWidth: 300)
            VStack(spacing: 6) {
                Text("No controller connected").font(.headline)
                Text("Turn on your controller and pair it in Settings → Bluetooth. Your iPhone supports Xbox, PlayStation, Switch Pro and MFi controllers; most others work in their Xbox or X-input mode.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .secondaryGlassButton()
        }
        .padding(22)
        .frame(maxWidth: .infinity)
        .glassSurface(cornerRadius: 22)
    }
}
