import GameController
import SwiftUI

// Controller types shared by the Mac's Controllers pane and the iPhone's controller check.

enum PadButton: Hashable, CaseIterable {
    case a, b, x, y, leftShoulder, rightShoulder, leftStick, rightStick
    case dpadUp, dpadDown, dpadLeft, dpadRight, view, menu, home
}

/// Everything the drawn gamepad shows at one moment.
struct PadState: Equatable {
    var pressed: Set<PadButton> = []
    var leftStick = CGPoint.zero
    var rightStick = CGPoint.zero
    var leftTrigger = 0.0
    var rightTrigger = 0.0
}

/// Which labels the face buttons get. The drawing keeps one layout; the glyphs follow the controller.
enum PadStyle {
    case xbox, playStation, nintendo

    func label(_ button: PadButton) -> String {
        switch (self, button) {
        case (.playStation, .a): "✕"
        case (.playStation, .b): "○"
        case (.playStation, .x): "□"
        case (.playStation, .y): "△"
        case (.nintendo, .a): "B"
        case (.nintendo, .b): "A"
        case (.nintendo, .x): "Y"
        case (.nintendo, .y): "X"
        case (_, .a): "A"
        case (_, .b): "B"
        case (_, .x): "X"
        case (_, .y): "Y"
        case (.playStation, .leftShoulder): "L1"
        case (.playStation, .rightShoulder): "R1"
        case (.nintendo, .leftShoulder): "L"
        case (.nintendo, .rightShoulder): "R"
        case (_, .leftShoulder): "LB"
        case (_, .rightShoulder): "RB"
        default: ""
        }
    }

    var triggerLabels: (String, String) {
        switch self {
        case .playStation: ("L2", "R2")
        case .nintendo: ("ZL", "ZR")
        case .xbox: ("LT", "RT")
        }
    }
}

extension PadState {
    /// The live state of a controller, read through Apple's GameController framework.
    init(_ pad: GCExtendedGamepad) {
        var s = PadState()
        let buttons: [(PadButton, GCControllerButtonInput?)] = [
            (.a, pad.buttonA), (.b, pad.buttonB), (.x, pad.buttonX), (.y, pad.buttonY),
            (.leftShoulder, pad.leftShoulder), (.rightShoulder, pad.rightShoulder),
            (.leftStick, pad.leftThumbstickButton), (.rightStick, pad.rightThumbstickButton),
            (.dpadUp, pad.dpad.up), (.dpadDown, pad.dpad.down), (.dpadLeft, pad.dpad.left), (.dpadRight, pad.dpad.right),
            (.view, pad.buttonOptions), (.menu, pad.buttonMenu), (.home, pad.buttonHome),
        ]
        for (button, input) in buttons where input?.isPressed == true { s.pressed.insert(button) }
        s.leftStick = CGPoint(x: Double(pad.leftThumbstick.xAxis.value), y: Double(pad.leftThumbstick.yAxis.value))
        s.rightStick = CGPoint(x: Double(pad.rightThumbstick.xAxis.value), y: Double(pad.rightThumbstick.yAxis.value))
        s.leftTrigger = Double(pad.leftTrigger.value)
        s.rightTrigger = Double(pad.rightTrigger.value)
        self = s
    }
}

extension PadStyle {
    /// The controller's family, from what Apple's GameController framework reports.
    init(_ controller: GCController) {
        let category = controller.productCategory.lowercased()
        self = category.contains("dualshock") || category.contains("dualsense") ? .playStation
            : category.contains("switch") || category.contains("joy-con") ? .nintendo : .xbox
    }
}
