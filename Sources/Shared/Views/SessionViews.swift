import SwiftUI
#if canImport(TrueCloudKit)
import TrueCloudKit
#endif

// Session views: the drawn display, the connection track, and the wording for each phase.

// MARK: - Display hero

/// A monitor whose screen shows the session state. The app's one illustration.
struct DisplayHero: View {
    let phase: SessionService.Phase
    /// Seconds the VM has been up, shown on the screen while it boots.
    var uptime: Int?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lastPhase: SessionService.Phase?
    @State private var flashScale: CGFloat = 0.02
    @State private var flashOpacity: Double = 0
    @State private var breathe = false

    private var isLit: Bool { phase == .ready || phase == .pairing }

    var body: some View {
        VStack(spacing: 0) {
            screen
                .aspectRatio(16 / 10, contentMode: .fit)
                .padding(7)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(LinearGradient(colors: [Color(white: 0.2), Color(white: 0.11)], startPoint: .top, endPoint: .bottom))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                )
                .shadow(color: isLit ? Color.tcAccent.opacity(0.45) : .black.opacity(0.22), radius: isLit ? 28 : 18, y: 10)
                .animation(.easeInOut(duration: 0.6), value: isLit)

            // Stand: neck and foot.
            Rectangle()
                .fill(LinearGradient(colors: [Color(white: 0.62), Color(white: 0.78)], startPoint: .top, endPoint: .bottom))
                .frame(width: 54, height: 26)
            Capsule()
                .fill(LinearGradient(colors: [Color(white: 0.82), Color(white: 0.66)], startPoint: .top, endPoint: .bottom))
                .frame(width: 120, height: 7)
                .shadow(color: .black.opacity(0.15), radius: 3, y: 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(phase.statusText)
        .onAppear { lastPhase = phase }
        .onChange(of: phase) { newPhase in
            if lastPhase == .idle && newPhase != .idle { powerOn() }
            lastPhase = newPhase
        }
    }

    private var screen: some View {
        ZStack {
            // Each state's colour is its own layer, so changes crossfade instead of snapping.
            ForEach(Self.screenStates, id: \.self) { state in
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Self.background(for: state))
                    .opacity(phase.screenState == state ? 1 : 0)
            }
            .animation(.easeInOut(duration: 0.5), value: phase.screenState)

            content
                .id(phase.screenState)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.85)))
                .animation(.spring(response: 0.5, dampingFraction: 0.8), value: phase.screenState)

            // Power-on: a bright line opens to fill the screen and fades, like an old monitor waking up.
            Rectangle()
                .fill(.white)
                .scaleEffect(x: 1, y: flashScale)
                .opacity(flashOpacity)
                .blendMode(.plusLighter)

            // Glass reflection.
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(LinearGradient(colors: [.white.opacity(0.09), .clear], startPoint: .topLeading, endPoint: .center))
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func powerOn() {
        guard !reduceMotion else { return }
        flashScale = 0.02
        flashOpacity = 0.9
        withAnimation(.easeOut(duration: 0.22)) { flashScale = 1 }
        withAnimation(.easeOut(duration: 0.6).delay(0.18)) { flashOpacity = 0 }
    }

    private var workingSymbol: String {
        switch phase {
        case .checking: "antenna.radiowaves.left.and.right"
        case .starting: "power"
        case .shuttingDown: "moon.zzz"
        default: "cpu"
        }
    }

    private static func clock(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private static let screenStates = ["off", "working", "lit", "live"]

    private static func background(for state: String) -> LinearGradient {
        switch state {
        case "lit":
            LinearGradient(colors: [Color.tcAccent, Color.tcAccentDeep], startPoint: .top, endPoint: .bottom)
        case "live":
            LinearGradient(colors: [Color(red: 0.05, green: 0.09, blue: 0.13), Color(red: 0.02, green: 0.04, blue: 0.06)], startPoint: .top, endPoint: .bottom)
        case "off":
            LinearGradient(colors: [Color(white: 0.09), Color(white: 0.04)], startPoint: .top, endPoint: .bottom)
        default:
            LinearGradient(colors: [Color.tcScreenTop, Color.tcScreenBottom], startPoint: .top, endPoint: .bottom)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .idle:
            Image(systemName: "power")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.white.opacity(0.22))
        case .checking, .starting, .booting, .shuttingDown:
            ZStack {
                ScanBand()
                VStack(spacing: 8) {
                    Image(systemName: workingSymbol)
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(.white.opacity(0.85))
                    if let uptime, phase == .starting || phase == .booting {
                        Text(Self.clock(uptime))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
            }
        case .ready:
            // Breathes gently: the one thing on screen asking to be pressed.
            Image(systemName: "play.circle.fill")
                .font(.system(size: 54, weight: .regular))
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.tcAccentDeep, .white)
                .shadow(color: .white.opacity(breathe ? 0.45 : 0.1), radius: breathe ? 16 : 6)
                .scaleEffect(breathe ? 1.06 : 1)
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { breathe = true }
                }
                .onDisappear { breathe = false }
        case .pairing:
            ZStack {
                ScanBand()
                Image(systemName: "link")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(.white)
            }
        case .streaming:
            VStack(spacing: 10) {
                HStack(spacing: 6) {
                    PulsingDot(color: .green)
                    Text("LIVE")
                        .font(.caption.weight(.bold))
                        .tracking(1.2)
                        .foregroundStyle(.white)
                }
                Text("Playing on your cloud PC")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }
}

/// A soft band of brand light sweeping down the screen while the PC is working.
private struct ScanBand: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.4
            GeometryReader { geo in
                LinearGradient(colors: [.clear, Color.tcAccent.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: geo.size.height * 0.45)
                    .offset(y: geo.size.height * (t * 1.45 - 0.45))
            }
        }
        .allowsHitTesting(false)
    }
}

struct PulsingDot: View {
    let color: Color
    @State private var on = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .background(Circle().fill(color.opacity(0.4)).scaleEffect(on ? 2.4 : 1).opacity(on ? 0 : 1))
            .onAppear {
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { on = true }
            }
    }
}

// MARK: - Connection track

/// Power on → Boot → Sunshine → Play, with the current step highlighted.
struct ConnectionTrack: View {
    let phase: SessionService.Phase

    private static let steps = ["Power on", "Boot", "Sunshine", "Play"]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Self.steps.indices, id: \.self) { i in
                if i > 0 {
                    // The accent fill grows along the line, one segment after another.
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.25))
                        Capsule()
                            .fill(Color.tcAccent)
                            .scaleEffect(x: i <= phase.completedSteps ? 1 : 0, anchor: .leading)
                            .animation(.easeInOut(duration: 0.45).delay(Double(i) * 0.12), value: phase.completedSteps)
                    }
                    .frame(height: 2)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 20)
                }
                step(i)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(min(phase.completedSteps + 1, 4)) of 4")
    }

    private func step(_ i: Int) -> some View {
        let done = i < phase.completedSteps
        let current = i == phase.currentStep
        return VStack(spacing: 7) {
            ZStack {
                Circle()
                    .fill(done ? Color.tcAccent : Color.clear)
                    .overlay(Circle().strokeBorder(done || current ? Color.tcAccent : Color.secondary.opacity(0.35), lineWidth: 1.5))
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .transition(.scale(scale: 0.2).combined(with: .opacity))
                } else if current {
                    PulsingDot(color: .tcAccent)
                        .transition(.opacity)
                }
            }
            .frame(width: 18, height: 18)
            .scaleEffect(current ? 1.12 : 1)
            .animation(.spring(response: 0.35, dampingFraction: 0.55).delay(Double(i) * 0.12), value: done)
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: current)
            Text(Self.steps[i])
                .font(.caption)
                .foregroundStyle(done || current ? .primary : .secondary)
        }
        .fixedSize()
    }
}

extension SessionService.Phase {
    /// What the drawn screen shows; the screen only changes when this does.
    var screenState: String {
        switch self {
        case .idle: "off"
        case .checking, .starting, .booting, .shuttingDown: "working"
        case .ready, .pairing: "lit"
        case .streaming: "live"
        }
    }

    /// Steps of the connection track that are finished.
    var completedSteps: Int {
        switch self {
        case .idle, .checking, .shuttingDown: 0
        case .starting: 1
        case .booting: 2
        case .ready, .pairing: 3
        case .streaming: 4
        }
    }

    /// The step in progress, or nil when nothing is moving.
    var currentStep: Int? {
        switch self {
        case .starting: 1
        case .booting: 2
        case .pairing: 3
        default: nil
        }
    }

    var detailText: String {
        switch self {
        case .checking: "Asking TrueCloud about your cloud PC."
        case .idle: "Start it when you're ready to play."
        case .starting: "Power is on. Windows is starting, which takes about a minute."
        case .booting: "Windows is up. Waiting for Sunshine, the streaming service, to answer."
        case .ready: "Press Play to open the stream in Moonlight."
        case .pairing: "Pairing Moonlight with your cloud PC. No PIN needed."
        case .streaming: "Your cloud PC is streaming."
        case .shuttingDown: "Windows is closing down. Plan time stops when it's off."
        }
    }

    /// Dot shown next to "Cloud PC" in the sidebar; nil when the PC is off.
    var indicatorColor: Color? {
        switch self {
        case .idle, .checking: nil
        case .ready, .streaming: .green
        default: .orange
        }
    }
}

extension RigProfile {
    var firstName: String {
        displayName.split(separator: " ").first.map(String.init) ?? "Player"
    }

    var initial: String { String(firstName.prefix(1)).uppercased() }

    /// "3h 57m"
    static func clock(hours: Double) -> String {
        PlanUsage.duration(Int((hours * 60).rounded()))
    }
}

// MARK: - Plan

/// Plan time left as a bar, with the daily quota.
struct PlanUsage: View {
    let profile: RigProfile
    var compact = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var filled = false

    var body: some View {
        // Counts up and fills when it first appears.
        let total = profile.minutesLeft ?? 0
        let left = filled ? total : 0
        VStack(alignment: .leading, spacing: compact ? 5 : 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Time left").foregroundStyle(.secondary)
                Spacer()
                if profile.isUnlimited {
                    Text("Unlimited").fontWeight(compact ? .regular : .semibold)
                } else {
                    Text(Self.duration(left))
                        .monospacedDigit()
                        .fontWeight(compact ? .regular : .semibold)
                        .contentTransition(.numericText())
                }
            }
            .font(compact ? .caption : .subheadline)
            if !profile.isUnlimited {
                AccentBar(value: Double(left) / max(profile.planHours * 60, Double(total), 1), height: compact ? 4 : 6)
            }
            if let end = profile.expiration {
                HStack(alignment: .firstTextBaseline) {
                    Text("Valid until").foregroundStyle(.secondary)
                    Spacer()
                    Text(Self.validity(of: profile, end: end))
                        .monospacedDigit()
                        .foregroundStyle(Self.validityTint(of: profile) ?? Color.primary)
                }
                .font(compact ? .caption : .subheadline)
            }
        }
        .onAppear {
            guard !filled else { return }
            if reduceMotion { filled = true; return }
            withAnimation(.easeOut(duration: 1.1).delay(0.3)) { filled = true }
        }
    }

    static func dateText(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).year())
    }

    /// The end date, worded for its state: "Expired 3 Nov 2026", "3 Nov 2026 · 2 days left" or just the date.
    static func validity(of profile: RigProfile, end: Date) -> String {
        let date = dateText(end)
        if profile.isExpired() { return "Expired \(date)" }
        if profile.isExpiringSoon(), let days = profile.daysUntilExpiry() {
            switch days {
            case ..<1: return "\(date) · ends today"
            case 1: return "\(date) · 1 day left"
            default: return "\(date) · \(days) days left"
            }
        }
        return date
    }

    /// Red once expired, orange in the last days, nil otherwise.
    static func validityTint(of profile: RigProfile) -> Color? {
        if profile.isExpired() { return .red }
        if profile.isExpiringSoon() { return .orange }
        return nil
    }

    static func duration(_ minutes: Int) -> String {
        minutes >= 60 ? (minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m") : "\(minutes)m"
    }
}

/// Initial avatar, first name and plan.
struct ProfileBadge: View {
    let profile: RigProfile
    var size: CGFloat = 26

    var body: some View {
        HStack(spacing: size * 0.35) {
            Text(profile.initial)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Color.tcAccent.gradient, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.firstName).font(size > 30 ? .headline : .callout.weight(.medium))
                Label(profile.planName, systemImage: "star.fill")
                    .font(size > 30 ? .subheadline : .caption)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }
        }
    }
}

// MARK: - Motion

/// Fades content up into place the first time it appears, after `delay`. With Reduce Motion it
/// only fades.
private struct Reveal: ViewModifier {
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 18)
            .scaleEffect(shown || reduceMotion ? 1 : 0.98)
            .onAppear {
                guard !shown else { return }
                withAnimation(reduceMotion ? .easeOut(duration: 0.25) : .spring(response: 0.6, dampingFraction: 0.86).delay(delay)) {
                    shown = true
                }
            }
    }
}

/// A short horizontal shake, driven by a counter that goes up on each failure.
struct Shake: GeometryEffect {
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 9 * sin(animatableData * .pi * 4), y: 0))
    }
}

extension View {
    func reveal(_ delay: Double = 0) -> some View { modifier(Reveal(delay: delay)) }
}
