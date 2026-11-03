import UIKit

// The on-screen gamepad's layout: which controls exist, where they sit, how big they are and which
// ones the player hid. Positions are fractions (0…1) of the area the controls may use, so a layout
// carries over between iPhone sizes, and between portrait-safe areas and notches.

/// A movable control. The four face buttons and the four D-pad pieces move as one cluster each.
enum OSCElement: String, CaseIterable, Codable {
    case leftStick, rightStick, dpad, face, back, start, lb, rb, lt, rt, ls, rs

    var title: String {
        switch self {
        case .leftStick: "Left stick"
        case .rightStick: "Right stick"
        case .dpad: "D-pad"
        case .face: "A B X Y buttons"
        case .back: "Back"
        case .start: "Start"
        case .lb: "Left bumper (LB)"
        case .rb: "Right bumper (RB)"
        case .lt: "Left trigger (LT)"
        case .rt: "Right trigger (RT)"
        case .ls: "Left stick click (LS)"
        case .rs: "Right stick click (RS)"
        }
    }

    /// Where the control sits by default, as fractions of the control area (laid out after the glass
    /// gamepad reference: sticks and D-pad low on the left, A B X Y low on the right, shoulder buttons
    /// on a diagonal, Back and Start at the top).
    var defaultPosition: CGPoint {
        switch self {
        case .back: CGPoint(x: 0.27, y: 0.07)
        case .start: CGPoint(x: 0.73, y: 0.07)
        case .lt: CGPoint(x: 0.10, y: 0.25)
        case .lb: CGPoint(x: 0.165, y: 0.37)
        case .rt: CGPoint(x: 0.90, y: 0.25)
        case .rb: CGPoint(x: 0.835, y: 0.37)
        case .ls: CGPoint(x: 0.045, y: 0.54)
        case .rs: CGPoint(x: 0.955, y: 0.54)
        case .leftStick: CGPoint(x: 0.14, y: 0.76)
        case .dpad: CGPoint(x: 0.36, y: 0.76)
        case .rightStick: CGPoint(x: 0.62, y: 0.77)
        case .face: CGPoint(x: 0.85, y: 0.73)
        }
    }

    /// The controls Moonlight wants on screen for a given level. Auto levels are chosen by
    /// ControllerSupport from the physical gamepad that's connected (it may lack triggers, sticks, etc.).
    static func visible(for level: OnScreenControlsLevel) -> Set<OSCElement> {
        switch level {
        case .simple: [.dpad, .face, .start, .back]
        case .full: Set(OSCElement.allCases)
        case .autoGCGamepad: [.lt, .rt, .start, .back, .leftStick, .rightStick]
        case .autoGCExtendedGamepad: [.start, .back, .ls, .rs]
        case .autoGCExtendedGamepadWithStickButtons: [.start, .back]
        default: []
        }
    }
}

struct OSCItem: Codable, Equatable {
    /// Centre of the control, as fractions of the control area.
    var x: Double
    var y: Double
    /// 1 is the standard size.
    var scale: Double = 1
    var hidden = false
}

struct OSCLayout: Codable, Equatable {
    /// How opaque the whole gamepad is while playing.
    var opacity = 0.9
    /// Keyed by `OSCElement.rawValue`; a missing entry means "the default position".
    var items: [String: OSCItem] = [:]
    /// Touch anywhere on the left or right half of the screen and a stick appears under the finger (Steam Link's
    /// "dynamic joysticks"). The fixed sticks are hidden while this is on.
    var floatingSticks = false
    /// Seconds without a touch before the controls fade out; 0 keeps them always visible.
    var fadeAfter = 0.0

    static let opacityRange = 0.3...1.0
    static let scaleRange = 0.6...1.8
    static let fadeChoices: [Double] = [0, 5, 10, 20]

    init() {}

    /// Layouts saved before these fields existed have no keys for them; decoding must not throw away the player's layout.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 0.9
        items = try c.decodeIfPresent([String: OSCItem].self, forKey: .items) ?? [:]
        floatingSticks = try c.decodeIfPresent(Bool.self, forKey: .floatingSticks) ?? false
        fadeAfter = try c.decodeIfPresent(Double.self, forKey: .fadeAfter) ?? 0
    }

    func item(_ element: OSCElement) -> OSCItem {
        items[element.rawValue] ?? OSCItem(x: element.defaultPosition.x, y: element.defaultPosition.y)
    }

    mutating func set(_ element: OSCElement, _ item: OSCItem) {
        items[element.rawValue] = item
    }

    var isDefault: Bool { self == OSCLayout() }
}

/// The player's layout, kept in UserDefaults so the stream and the editor see the same one.
enum OSCLayoutStore {
    private static let key = "truecloud.osc.layout.v1"

    static func load() -> OSCLayout {
        guard let data = UserDefaults.standard.data(forKey: key),
              var layout = try? JSONDecoder().decode(OSCLayout.self, from: data) else { return OSCLayout() }
        layout.opacity = min(max(layout.opacity, OSCLayout.opacityRange.lowerBound), OSCLayout.opacityRange.upperBound)
        return layout
    }

    static func save(_ layout: OSCLayout) {
        if layout.isDefault {
            UserDefaults.standard.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(layout) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

extension Notification.Name {
    /// Posted by the in-stream overlay to start editing the on-screen controls over the running stream.
    static let trueCloudEditControls = Notification.Name("TrueCloudEditControls")
}
