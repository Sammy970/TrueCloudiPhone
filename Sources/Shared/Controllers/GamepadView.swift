import SwiftUI

/// A drawn controller showing live input: pressed buttons light up in TrueCloud blue, the sticks move with
/// the real ones, and the triggers fill as they're pulled. One Xbox-style body for every controller; the
/// face-button labels and their colours follow its family (✕○□△ on PlayStation).
struct GamepadView: View {
    let state: PadState
    var style = PadStyle.xbox
    /// Draws an unlit, unlabelled controller, for the empty state.
    var dimmed = false

    @Environment(\.colorScheme) private var scheme

    /// Everything is laid out on a 480 × 340 grid and scaled to fit.
    private static let size = CGSize(width: 480, height: 340)

    private static let leftStick = CGPoint(x: 152, y: 142)
    private static let rightStick = CGPoint(x: 290, y: 200)
    private static let dpad = CGPoint(x: 190, y: 200)
    private static let faceButtons = CGPoint(x: 328, y: 142)

    var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / Self.size.width, geo.size.height / Self.size.height)
            ZStack(alignment: .topLeading) {
                triggers
                bumper(.leftShoulder, center: CGPoint(x: 140, y: 84), angle: -7)
                bumper(.rightShoulder, center: CGPoint(x: 340, y: 84), angle: 7)
                shell
                well(at: Self.leftStick, size: 76)
                well(at: Self.rightStick, size: 76)
                well(at: Self.dpad, size: 72)
                stick(state.leftStick, pressed: state.pressed.contains(.leftStick), at: Self.leftStick)
                stick(state.rightStick, pressed: state.pressed.contains(.rightStick), at: Self.rightStick)
                dpad(at: Self.dpad)
                faceButtons(at: Self.faceButtons)
                centerButtons
            }
            .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
            .scaleEffect(scale, anchor: .topLeading)
            // Top-leading, so the full-size drawing scales into this frame instead of being centred in it first.
            .frame(width: Self.size.width * scale, height: Self.size.height * scale, alignment: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(Self.size.width / Self.size.height, contentMode: .fit)
        .opacity(dimmed ? 0.45 : 1)
        .animation(.easeOut(duration: 0.08), value: state)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Controller")
    }

    // MARK: Colours

    private var dark: Bool { scheme == .dark }
    private var bodyTop: Color { dark ? Color(white: 0.27) : Color(white: 0.99) }
    private var bodyBottom: Color { dark ? Color(white: 0.15) : Color(white: 0.86) }
    /// Buttons and sticks: near-black on both themes, like a real controller's.
    private var control: Color { dark ? Color(white: 0.09) : Color(white: 0.2) }
    private var recess: Color { dark ? .black.opacity(0.35) : .black.opacity(0.09) }
    private var track: Color { dark ? Color(white: 0.12) : Color(white: 0.82) }

    private func fill(_ on: Bool) -> Color { on && !dimmed ? .tcAccent : control }

    // MARK: Body

    /// One continuous outline: a gently curved top, shoulders, and two grips that sweep down and out.
    private var shell: some View {
        ControllerShape()
            .fill(LinearGradient(colors: [bodyTop, bodyBottom], startPoint: .top, endPoint: .bottom))
            .overlay(
                // A soft highlight along the top edge, fading out before the grips.
                ControllerShape()
                    .stroke(LinearGradient(colors: [.white.opacity(dark ? 0.18 : 0.9), .clear], startPoint: .top, endPoint: .center), lineWidth: 1.5)
            )
            .overlay(ControllerShape().stroke(.black.opacity(dark ? 0.5 : 0.1), lineWidth: 0.5))
            .shadow(color: .black.opacity(dark ? 0.55 : 0.2), radius: 16, y: 10)
    }

    /// A shallow dish in the body around a stick or the D-pad.
    private func well(at center: CGPoint, size: CGFloat) -> some View {
        Circle()
            .fill(RadialGradient(colors: [recess, recess.opacity(0.4)], center: .top, startRadius: 0, endRadius: size))
            .overlay(Circle().stroke(.white.opacity(dark ? 0.05 : 0.6), lineWidth: 1).offset(y: 1))
            .frame(width: size, height: size)
            .position(center)
    }

    private func bumper(_ button: PadButton, center: CGPoint, angle: Double) -> some View {
        let on = state.pressed.contains(button) && !dimmed
        return RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(on ? Color.tcAccent : control)
            .overlay(alignment: .top) {
                Text(dimmed ? "" : style.label(button))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(on ? 1 : 0.6))
                    .padding(.top, 3)
            }
            .frame(width: 104, height: 30)
            .rotationEffect(.degrees(angle))
            .shadow(color: on ? Color.tcAccent.opacity(0.7) : .clear, radius: 10)
            .position(center)
    }

    /// Trigger fill bars, above the shoulders.
    private var triggers: some View {
        let (left, right) = style.triggerLabels
        return HStack(spacing: 0) {
            triggerBar(left, value: state.leftTrigger)
            Spacer()
            triggerBar(right, value: state.rightTrigger)
        }
        .frame(width: 300)
        .offset(x: 90, y: 4)
    }

    private func triggerBar(_ label: String, value: Double) -> some View {
        VStack(spacing: 4) {
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(Color.tcAccent).frame(width: dimmed ? 0 : 96 * value)
            }
            .frame(width: 96, height: 10)
            Text(dimmed ? label : "\(label) \(Int((value * 100).rounded()))%")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Controls

    private func stick(_ value: CGPoint, pressed: Bool, at center: CGPoint) -> some View {
        let on = pressed && !dimmed
        return ZStack {
            // Base ring the stick pivots in.
            Circle().fill(control).frame(width: 62, height: 62)
            // Thumb: a concave cap that follows the stick (up on the stick is up on screen).
            Circle()
                .fill(RadialGradient(colors: on ? [Color.tcAccent.opacity(0.75), .tcAccent] : [Color(white: 0.17), Color(white: 0.27)],
                                     center: .center, startRadius: 2, endRadius: 24))
                .overlay(Circle().stroke(.white.opacity(0.12), lineWidth: 1))
                .frame(width: 46, height: 46)
                .shadow(color: .black.opacity(0.45), radius: 3, y: 2)
                .offset(x: value.x * 12, y: -value.y * 12)
        }
        .shadow(color: on ? Color.tcAccent.opacity(0.6) : .clear, radius: 10)
        .position(center)
    }

    private func dpad(at center: CGPoint) -> some View {
        let arms: [(PadButton, CGSize, Double)] = [
            (.dpadUp, CGSize(width: 0, height: -16), 0), (.dpadDown, CGSize(width: 0, height: 16), 180),
            (.dpadLeft, CGSize(width: -16, height: 0), 270), (.dpadRight, CGSize(width: 16, height: 0), 90),
        ]
        return ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(control).frame(width: 22, height: 58)
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(control).frame(width: 58, height: 22)
            ForEach(arms, id: \.0) { button, offset, angle in
                let on = state.pressed.contains(button) && !dimmed
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(on ? Color.tcAccent : .clear)
                    .frame(width: 20, height: 20)
                    .overlay(
                        Image(systemName: "arrowtriangle.up.fill")
                            .font(.system(size: 7))
                            .foregroundStyle(.white.opacity(on ? 1 : 0.35))
                            .rotationEffect(.degrees(angle))
                    )
                    .shadow(color: on ? Color.tcAccent.opacity(0.7) : .clear, radius: 8)
                    .offset(offset)
            }
        }
        .position(center)
    }

    private func faceButtons(at center: CGPoint) -> some View {
        let buttons: [(PadButton, CGSize)] = [
            (.y, CGSize(width: 0, height: -28)), (.a, CGSize(width: 0, height: 28)),
            (.x, CGSize(width: -28, height: 0)), (.b, CGSize(width: 28, height: 0)),
        ]
        return ZStack {
            ForEach(buttons, id: \.0) { button, offset in
                let on = state.pressed.contains(button) && !dimmed
                Circle()
                    .fill(on ? Color.tcAccent : control)
                    .overlay(Circle().stroke(.white.opacity(0.1), lineWidth: 1))
                    .overlay(
                        Text(dimmed ? "" : style.label(button))
                            .font(.system(size: style == .playStation ? 14 : 13, weight: .heavy))
                            .foregroundStyle(on ? .white : glyphColor(button))
                    )
                    .frame(width: 28, height: 28)
                    .shadow(color: on ? Color.tcAccent.opacity(0.8) : .black.opacity(0.35), radius: on ? 9 : 2, y: on ? 0 : 1)
                    .offset(offset)
            }
        }
        .position(center)
    }

    /// Letter colours as printed on the real controllers.
    private func glyphColor(_ button: PadButton) -> Color {
        switch (style, button) {
        case (.xbox, .a): Color(red: 0.42, green: 0.8, blue: 0.27)
        case (.xbox, .b): Color(red: 0.93, green: 0.3, blue: 0.27)
        case (.xbox, .x): Color(red: 0.25, green: 0.55, blue: 0.95)
        case (.xbox, .y): Color(red: 1, green: 0.78, blue: 0.2)
        case (.playStation, .a): Color(red: 0.5, green: 0.65, blue: 1)
        case (.playStation, .b): Color(red: 1, green: 0.45, blue: 0.45)
        case (.playStation, .x): Color(red: 0.95, green: 0.55, blue: 0.85)
        case (.playStation, .y): Color(red: 0.35, green: 0.85, blue: 0.7)
        default: .white.opacity(0.85)
        }
    }

    private var centerButtons: some View {
        ZStack {
            centerPill(.view, at: CGPoint(x: 214, y: 150), symbol: "rectangle.on.rectangle")
            centerPill(.menu, at: CGPoint(x: 266, y: 150), symbol: "line.3.horizontal")
            let home = state.pressed.contains(.home) && !dimmed
            Circle()
                .fill(home ? Color.tcAccent : control)
                .overlay(Circle().stroke(.white.opacity(0.15), lineWidth: 1))
                .overlay(Image(systemName: "gamecontroller.fill").font(.system(size: 11)).foregroundStyle(.white.opacity(home ? 1 : 0.5)))
                .frame(width: 32, height: 32)
                .shadow(color: home ? Color.tcAccent.opacity(0.7) : .clear, radius: 9)
                .position(x: 240, y: 102)
        }
    }

    private func centerPill(_ button: PadButton, at center: CGPoint, symbol: String) -> some View {
        let on = state.pressed.contains(button) && !dimmed
        return Circle()
            .fill(on ? Color.tcAccent : control)
            .overlay(Image(systemName: symbol).font(.system(size: 7, weight: .bold)).foregroundStyle(.white.opacity(on ? 1 : 0.55)))
            .frame(width: 18, height: 18)
            .shadow(color: on ? Color.tcAccent.opacity(0.7) : .clear, radius: 7)
            .position(center)
    }
}

/// The controller's outline on the 480 × 340 grid: the left half as curves, mirrored for the right.
private struct ControllerShape: Shape {
    /// Left half, from the top centre around the left grip to the bottom centre. Each entry is a cubic
    /// curve: end point, then its two control points.
    private static let leftHalf: [(end: CGPoint, c1: CGPoint, c2: CGPoint)] = [
        (CGPoint(x: 118, y: 92), CGPoint(x: 196, y: 80), CGPoint(x: 150, y: 80)),      // top edge out to the shoulder
        (CGPoint(x: 52, y: 166), CGPoint(x: 82, y: 102), CGPoint(x: 60, y: 126)),       // shoulder curving down the side
        (CGPoint(x: 50, y: 288), CGPoint(x: 42, y: 212), CGPoint(x: 34, y: 256)),       // outer edge of the grip
        (CGPoint(x: 124, y: 304), CGPoint(x: 66, y: 322), CGPoint(x: 106, y: 326)),     // round bottom of the grip
        (CGPoint(x: 194, y: 252), CGPoint(x: 142, y: 282), CGPoint(x: 162, y: 254)),    // inner edge rising to the middle
        (CGPoint(x: 240, y: 250), CGPoint(x: 214, y: 250), CGPoint(x: 228, y: 250)),    // underside to the bottom centre
    ]

    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 480, sy = rect.height / 340
        func p(_ point: CGPoint) -> CGPoint { CGPoint(x: rect.minX + point.x * sx, y: rect.minY + point.y * sy) }
        func m(_ point: CGPoint) -> CGPoint { CGPoint(x: 480 - point.x, y: point.y) }

        var path = Path()
        path.move(to: p(CGPoint(x: 240, y: 80)))
        for segment in Self.leftHalf {
            path.addCurve(to: p(segment.end), control1: p(segment.c1), control2: p(segment.c2))
        }
        // Mirror back up the right side: reversed order, with each curve's control points swapped.
        let starts = [CGPoint(x: 240, y: 80)] + Self.leftHalf.map(\.end)
        for i in Self.leftHalf.indices.reversed() {
            let segment = Self.leftHalf[i]
            path.addCurve(to: p(m(starts[i])), control1: p(m(segment.c2)), control2: p(m(segment.c1)))
        }
        path.closeSubpath()
        return path
    }
}
