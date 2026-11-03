import UIKit

// MARK: - Output

/// Where the controls send what the player presses. In a stream that's Moonlight's ControllerSupport;
/// the editor's "Try it" mode and the self-test use a recording output instead.
protocol OSCOutput: AnyObject {
    func press(_ flags: Int32)
    func release(_ flags: Int32)
    func leftStick(x: Int16, y: Int16)
    func rightStick(x: Int16, y: Int16)
    func leftTrigger(_ value: UInt8)
    func rightTrigger(_ value: UInt8)
    /// Sends everything changed since the last call.
    func commit()
}

/// Button flags, as in Moonlight's Limelight.h.
enum OSCFlag {
    static let a: Int32 = 0x1000, b: Int32 = 0x2000, x: Int32 = 0x4000, y: Int32 = 0x8000
    static let up: Int32 = 0x0001, down: Int32 = 0x0002, left: Int32 = 0x0004, right: Int32 = 0x0008
    static let lb: Int32 = 0x0100, rb: Int32 = 0x0200
    static let start: Int32 = 0x0010, back: Int32 = 0x0020
    static let ls: Int32 = 0x0040, rs: Int32 = 0x0080
    static let dpad = up | down | left | right
}

/// Sends to the cloud PC through Moonlight's ControllerSupport, as the stock on-screen controls do.
final class OSCControllerOutput: OSCOutput {
    private let support: ControllerSupport
    private let controller: Controller

    init?(support: ControllerSupport?) {
        guard let support, let controller = support.getOscController() else { return nil }
        self.support = support
        self.controller = controller
    }

    func press(_ flags: Int32) { support.setButtonFlag(controller, flags: flags) }
    func release(_ flags: Int32) { support.clearButtonFlag(controller, flags: flags) }
    func leftStick(x: Int16, y: Int16) { support.updateLeftStick(controller, x: x, y: y) }
    func rightStick(x: Int16, y: Int16) { support.updateRightStick(controller, x: x, y: y) }
    func leftTrigger(_ value: UInt8) { support.updateLeftTrigger(controller, left: value) }
    func rightTrigger(_ value: UInt8) { support.updateRightTrigger(controller, right: value) }
    func commit() { support.updateFinished(controller) }
}

/// Keeps what was pressed instead of sending it.
final class OSCRecordingOutput: OSCOutput {
    private(set) var flags: Int32 = 0
    private(set) var lx: Int16 = 0, ly: Int16 = 0, rx: Int16 = 0, ry: Int16 = 0
    private(set) var lt: UInt8 = 0, rt: UInt8 = 0
    private(set) var commits = 0

    func press(_ flags: Int32) { self.flags |= flags }
    func release(_ flags: Int32) { self.flags &= ~flags }
    func leftStick(x: Int16, y: Int16) { lx = x; ly = y }
    func rightStick(x: Int16, y: Int16) { rx = x; ry = y }
    func leftTrigger(_ value: UInt8) { lt = value }
    func rightTrigger(_ value: UInt8) { rt = value }
    func commit() { commits += 1 }
}

// MARK: - Parts

/// One drawn piece. Elements are made of one or more parts.
enum OSCPart: Hashable, CaseIterable {
    case a, b, x, y, up, down, left, right
    case start, back, lb, rb, lt, rt, ls, rs
    case leftBase, leftKnob, rightBase, rightKnob

    var element: OSCElement {
        switch self {
        case .a, .b, .x, .y: .face
        case .up, .down, .left, .right: .dpad
        case .start: .start
        case .back: .back
        case .lb: .lb
        case .rb: .rb
        case .lt: .lt
        case .rt: .rt
        case .ls: .ls
        case .rs: .rs
        case .leftBase, .leftKnob: .leftStick
        case .rightBase, .rightKnob: .rightStick
        }
    }
}

private enum OSCHold {
    case button(OSCPart)
    case dpad
    case stick(left: Bool)
    /// Touched next to a control without hitting it: swallowed so it doesn't move the cursor.
    case dead
    case drag(OSCElement, grab: CGSize)
    /// Editing: a finger on empty space. It moves nothing, but a second finger can pair with it to pinch.
    case blank
    /// Editing: one of the two fingers of a pinch (see `editPinchMoved`).
    case pinch
}

// MARK: - Controls

/// TrueCloud's on-screen gamepad: glass controls laid out after the player's saved layout, with the same
/// behaviour as Moonlight's stock `OnScreenControls` (which it replaces; see the StreamView patch), plus an
/// edit mode for moving, resizing and hiding controls.
@MainActor
@objc(TrueCloudOnScreenControls)
final class TrueCloudOnScreenControls: NSObject {
    // Sizes at the standard scale, in points.
    private static let faceDiameter: CGFloat = 50, faceOffsetX: CGFloat = 68, faceOffsetY: CGFloat = 55
    private static let dpadOffset: CGFloat = 41, dpadShort: CGFloat = 42, dpadLong: CGFloat = 52
    private static let stickOuter: CGFloat = 124, stickInner: CGFloat = 58
    private static let gem = CGSize(width: 58, height: 54)
    private static let pill = CGSize(width: 66, height: 38)
    private static let clickDiameter: CGFloat = 46
    private static let stickDeadZone: CGFloat = 0.1
    private static let stickClickWindow: TimeInterval = 0.1
    private static let deadZonePadding: CGFloat = 18

    private weak var view: UIView?
    private let output: OSCOutput?
    private let swapABXY: Bool
    private(set) var level: OnScreenControlsLevel = .off
    private(set) var layout: OSCLayout
    private var visible = false

    private let root = CALayer()
    private let selection = CAShapeLayer()
    private let guides = CAShapeLayer()
    /// While arranging: a faint blue wash over the whole screen, and a red outline on controls that overlap.
    private let tint = CALayer()
    private let overlaps = CAShapeLayer()
    private var layers: [OSCPart: CALayer] = [:]
    private var rects: [OSCPart: CGRect] = [:]
    private var lastBounds = CGRect.zero
    private var lastInsets = UIEdgeInsets.zero
    private var screenScale: CGFloat = 3

    private var holds: [Int: OSCHold] = [:]
    private var pressed: Set<OSCPart> = []
    private var knobOffset: [Bool: CGPoint] = [:]
    private var lastStickRelease: [Bool: Date] = [:]
    private var clickToggled: Set<OSCPart> = []
    private var dpadDirection: OSCPart?
    private lazy var haptic = UIImpactFeedbackGenerator(style: .light)
    private var editObserver: NSObjectProtocol?

    // Floating sticks: where each side's stick was spawned by a touch (left = true). Present only while a finger holds it.
    private var floatingCenter: [Bool: CGPoint] = [:]

    // Fade after idle
    /// Whether the idle fade has hidden the gamepad. `relayout` and `setOpacity` honour it so they don't un-fade it.
    private(set) var isFaded = false
    private var fadeTask: Task<Void, Never>?
    private var lastTouch: CFTimeInterval = 0

    // Editing
    private(set) var isEditing = false
    private(set) var selected: OSCElement?
    /// Called when the selection or layout changes, so an editor panel can refresh.
    var onChange: (() -> Void)?
    /// Called as a control is dragged while arranging: the element and the finger's position in the controls' view, then
    /// (nil, nil) when the drag ends or turns into a pinch. Only fires once the finger has moved a few points, so a tap doesn't.
    var onDragChange: ((_ element: OSCElement?, _ location: CGPoint?) -> Void)?
    /// Where the editor's bin is, in the controls' view. Lifting a dragged control with the finger inside it removes the control.
    var binFrame: CGRect?
    /// In-stream editing: the panel's own window above the stream. A window of its own keeps the
    /// stream view's gesture recognizers from stealing the panel's touches.
    private var panelWindow: PanelWindow?
    /// Whether "Try it" is on in a standalone editor: the controls then respond instead of moving.
    var isTrying = false {
        didSet {
            guard isTrying != oldValue else { return }
            releaseAll()
            relayout(force: true)
            onChange?()
        }
    }

    // MARK: Setup

    init(view: UIView, output: OSCOutput?, swapABXY: Bool) {
        self.view = view
        self.output = output
        self.swapABXY = swapABXY
        layout = OSCLayoutStore.load()
        super.init()
        root.zPosition = 1000
        selection.zPosition = 1001
        guides.zPosition = 1001
        tint.zPosition = 999  // under the controls, over the stream
        tint.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.14).cgColor
        overlaps.zPosition = 1002
        overlaps.strokeColor = UIColor.systemRed.withAlphaComponent(0.95).cgColor
        overlaps.lineWidth = 1.4
        overlaps.fillColor = nil
        selection.fillColor = OSCGlass.blue.withAlphaComponent(0.14).cgColor
        selection.strokeColor = UIColor.white.withAlphaComponent(0.9).cgColor
        selection.lineDashPattern = [7, 5]
        selection.lineWidth = 1.6
        guides.strokeColor = OSCGlass.blue.withAlphaComponent(0.9).cgColor
        guides.lineWidth = 1
        guides.fillColor = nil
    }

    /// The initialiser Moonlight's StreamView calls (see the patch), matching `OnScreenControls`.
    @objc(initWithView:controllerSup:streamConfig:)
    convenience init(view: UIView, controllerSup: ControllerSupport?, streamConfig: StreamConfiguration?) {
        self.init(view: view, output: OSCControllerOutput(support: controllerSup), swapABXY: streamConfig?.swapABXYButtons ?? false)
    }

    deinit {
        if let editObserver { NotificationCenter.default.removeObserver(editObserver) }
        fadeTask?.cancel()
        root.removeFromSuperlayer()
        selection.removeFromSuperlayer()
        guides.removeFromSuperlayer()
        tint.removeFromSuperlayer()
        overlaps.removeFromSuperlayer()
    }

    @objc(show)
    func show() {
        visible = true
        guard let view else { return }
        if root.superlayer !== view.layer { view.layer.addSublayer(root) }
        if editObserver == nil {
            editObserver = NotificationCenter.default.addObserver(forName: .trueCloudEditControls, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.beginStreamEditing() }
            }
        }
        relayout(force: true)
        wake()
    }

    @objc(setLevel:)
    func setLevel(_ level: OnScreenControlsLevel) {
        self.level = level
        if visible { relayout(force: true) }
    }

    @objc(getLevel)
    func getLevel() -> OnScreenControlsLevel { level }

    // MARK: Layout

    /// The area controls may sit in: the view minus the notch side, the home indicator and a small margin.
    private func limit(in view: UIView) -> CGRect {
        let b = view.bounds, s = view.safeAreaInsets
        let side = max(10, s.left * 0.55), sideRight = max(10, s.right * 0.55)
        let top = max(8, s.top), bottom = max(8, s.bottom)
        return CGRect(x: b.minX + side, y: b.minY + top, width: max(0, b.width - side - sideRight), height: max(0, b.height - top - bottom))
    }

    private func sizeFactor(_ view: UIView, item: OSCItem) -> CGFloat {
        let device: CGFloat = view.traitCollection.userInterfaceIdiom == .pad ? 1.3 : (view.bounds.height < 340 ? 0.88 : 1)
        return device * CGFloat(item.scale)
    }

    /// Rectangles of an element's parts around (0, 0) at a size factor.
    private func partRects(_ element: OSCElement, factor f: CGFloat) -> [(OSCPart, CGRect)] {
        func rect(_ w: CGFloat, _ h: CGFloat, at c: CGPoint = .zero) -> CGRect {
            CGRect(x: c.x - w * f / 2, y: c.y - h * f / 2, width: w * f, height: h * f)
        }
        switch element {
        case .face:
            let d = Self.faceDiameter, ox = Self.faceOffsetX * f, oy = Self.faceOffsetY * f
            let bottom = CGPoint(x: 0, y: oy), right = CGPoint(x: ox, y: 0), left = CGPoint(x: -ox, y: 0), top = CGPoint(x: 0, y: -oy)
            // Swapped: A and B trade places, as do X and Y (Nintendo-style).
            return swapABXY
                ? [(.a, rect(d, d, at: right)), (.b, rect(d, d, at: bottom)), (.x, rect(d, d, at: top)), (.y, rect(d, d, at: left))]
                : [(.a, rect(d, d, at: bottom)), (.b, rect(d, d, at: right)), (.x, rect(d, d, at: left)), (.y, rect(d, d, at: top))]
        case .dpad:
            let o = Self.dpadOffset * f, s = Self.dpadShort, l = Self.dpadLong
            return [(.up, rect(s, l, at: CGPoint(x: 0, y: -o))), (.down, rect(s, l, at: CGPoint(x: 0, y: o))),
                    (.left, rect(l, s, at: CGPoint(x: -o, y: 0))), (.right, rect(l, s, at: CGPoint(x: o, y: 0)))]
        case .leftStick: return [(.leftBase, rect(Self.stickOuter, Self.stickOuter))]
        case .rightStick: return [(.rightBase, rect(Self.stickOuter, Self.stickOuter))]
        case .start: return [(.start, rect(Self.pill.width, Self.pill.height))]
        case .back: return [(.back, rect(Self.pill.width, Self.pill.height))]
        case .lb: return [(.lb, rect(Self.gem.width, Self.gem.height))]
        case .rb: return [(.rb, rect(Self.gem.width, Self.gem.height))]
        case .lt: return [(.lt, rect(Self.gem.width, Self.gem.height))]
        case .rt: return [(.rt, rect(Self.gem.width, Self.gem.height))]
        case .ls: return [(.ls, rect(Self.clickDiameter, Self.clickDiameter))]
        case .rs: return [(.rs, rect(Self.clickDiameter, Self.clickDiameter))]
        }
    }

    private func union(_ parts: [(OSCPart, CGRect)]) -> CGRect {
        parts.map(\.1).reduce(CGRect.null) { $0.union($1) }
    }

    /// Where an element's centre is, with its frame kept inside the area.
    private func center(of element: OSCElement, in view: UIView) -> CGPoint {
        let item = layout.item(element), area = limit(in: view)
        let f = sizeFactor(view, item: item)
        let extent = union(partRects(element, factor: f))
        var c = CGPoint(x: area.minX + CGFloat(item.x) * area.width, y: area.minY + CGFloat(item.y) * area.height)
        c.x = min(max(c.x, area.minX - extent.minX), area.maxX - extent.maxX)
        c.y = min(max(c.y, area.minY - extent.minY), area.maxY - extent.maxY)
        return c
    }

    /// While arranging, every control shows (hidden ones faintly); otherwise only what the level and the player allow.
    private var isArranging: Bool { isEditing && !isTrying }

    /// Floating sticks replace the fixed ones while playing (the editor still arranges the fixed ones).
    private var isFloating: Bool { layout.floatingSticks && !isArranging }

    private func isShown(_ element: OSCElement) -> Bool {
        if isArranging { return true }
        // A floating stick exists only while its finger is down.
        if isFloating, element == .leftStick || element == .rightStick, floatingCenter[element == .leftStick] == nil { return false }
        return OSCElement.visible(for: level).contains(element) && !layout.item(element).hidden
    }

    /// Positions every control. Cheap enough to call whenever the size, level or layout changes.
    func relayout(force: Bool = false, only: OSCElement? = nil) {
        guard let view else { return }
        if !force, view.bounds == lastBounds, view.safeAreaInsets == lastInsets { return }
        lastBounds = view.bounds
        lastInsets = view.safeAreaInsets
        screenScale = view.window?.windowScene?.screen.scale ?? view.traitCollection.displayScale
        if screenScale < 1 { screenScale = 3 }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.frame = view.bounds
        // The editor always shows the controls at full opacity; otherwise an idle fade stays faded.
        if isEditing || layout.fadeAfter <= 0 { isFaded = false }
        if isEditing { fadeTask?.cancel(); fadeTask = nil }
        root.opacity = isFaded ? 0 : Float(layout.opacity)
        rects.removeAll()
        for element in OSCElement.allCases {
            let isStick = element == .leftStick || element == .rightStick
            let c = (isFloating && isStick ? floatingCenter[element == .leftStick] : nil) ?? center(of: element, in: view)
            let f = sizeFactor(view, item: layout.item(element))
            for (part, r) in partRects(element, factor: f) { rects[part] = r.offsetBy(dx: c.x, dy: c.y) }
            if element == .leftStick || element == .rightStick, let base = rects[element == .leftStick ? .leftBase : .rightBase] {
                let inner = Self.stickInner * f
                let isLeft = element == .leftStick
                let o = knobOffset[isLeft] ?? .zero
                rects[isLeft ? .leftKnob : .rightKnob] = CGRect(x: base.midX + o.x - inner / 2, y: base.midY + o.y - inner / 2, width: inner, height: inner)
            }
        }
        // While a slider is dragged only the control being changed needs its art redrawn.
        for part in OSCPart.allCases where only == nil || part.element == only { update(part) }
        updateSelection()
        CATransaction.commit()
        if !isEditing, fadeTask == nil { armFade() }
    }

    private func update(_ part: OSCPart) {
        guard let rect = rects[part] else { return }
        let layer = layers[part] ?? {
            let l = CALayer()
            layers[part] = l
            root.addSublayer(l)
            return l
        }()
        let element = part.element
        let shown = isShown(element)
        layer.isHidden = !shown
        guard shown else { return }
        let hiddenByPlayer = isArranging && layout.item(element).hidden
        layer.opacity = hiddenByPlayer ? 0.3 : 1
        let art = OSCGlass.art(spec(for: part, rect: rect, pressed: pressed.contains(part)))
        layer.contentsScale = screenScale
        layer.contents = art.image.cgImage
        layer.bounds = CGRect(origin: .zero, size: art.image.size)
        layer.position = CGPoint(x: rect.midX, y: rect.midY)
    }

    private func spec(for part: OSCPart, rect: CGRect, pressed: Bool) -> OSCGlass.Spec {
        let size = rect.size
        func make(_ shape: OSCGlass.Shape, _ label: String = "", angle: Int = 0) -> OSCGlass.Spec {
            OSCGlass.Spec(shape: shape, size: size, label: label, labelAngle: angle, pressed: pressed, scale: screenScale)
        }
        switch part {
        case .a: return make(.circle, "A")
        case .b: return make(.circle, "B")
        case .x: return make(.circle, "X")
        case .y: return make(.circle, "Y")
        case .up: return make(.dpad(.up))
        case .down: return make(.dpad(.down))
        case .left: return make(.dpad(.left))
        case .right: return make(.dpad(.right))
        case .start: return make(.pill, "START")
        case .back: return make(.pill, "BACK")
        case .lb: return make(.gem, "LB", angle: -42)
        case .rb: return make(.gem, "RB", angle: 42)
        case .lt: return make(.gem, "LT", angle: -42)
        case .rt: return make(.gem, "RT", angle: 42)
        case .ls: return make(.circle, "LS")
        case .rs: return make(.circle, "RS")
        case .leftBase, .rightBase: return make(.stickBase)
        case .leftKnob: return make(.knob, "L")
        case .rightKnob: return make(.knob, "R")
        }
    }

    private func frame(of element: OSCElement) -> CGRect {
        let parts: [OSCPart]
        switch element {
        case .face: parts = [.a, .b, .x, .y]
        case .dpad: parts = [.up, .down, .left, .right]
        case .leftStick: parts = [.leftBase]
        case .rightStick: parts = [.rightBase]
        case .start: parts = [.start]
        case .back: parts = [.back]
        case .lb: parts = [.lb]
        case .rb: parts = [.rb]
        case .lt: parts = [.lt]
        case .rt: parts = [.rt]
        case .ls: parts = [.ls]
        case .rs: parts = [.rs]
        }
        return parts.compactMap { rects[$0] }.reduce(CGRect.null) { $0.union($1) }
    }

    // MARK: Press visuals

    private func setPressed(_ part: OSCPart, _ on: Bool) {
        guard on != pressed.contains(part) else { return }
        if on { pressed.insert(part) } else { pressed.remove(part) }
        guard let layer = layers[part], let rect = rects[part] else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.08)
        layer.contents = OSCGlass.art(spec(for: part, rect: rect, pressed: on)).image.cgImage
        layer.transform = on && part != .leftBase && part != .rightBase ? CATransform3DMakeScale(0.94, 0.94, 1) : CATransform3DIdentity
        CATransaction.commit()
    }

    private func moveKnob(left: Bool, to offset: CGPoint) {
        knobOffset[left] = offset
        guard let base = rects[left ? .leftBase : .rightBase], let layer = layers[left ? .leftKnob : .rightKnob] else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.position = CGPoint(x: base.midX + offset.x, y: base.midY + offset.y)
        CATransaction.commit()
        let part: OSCPart = left ? .leftKnob : .rightKnob
        if var r = rects[part] {
            r.origin = CGPoint(x: base.midX + offset.x - r.width / 2, y: base.midY + offset.y - r.height / 2)
            rects[part] = r
        }
    }

    /// Where a part is on screen, for screenshots and the self-test.
    func partRect(_ part: OSCPart) -> CGRect? { rects[part] }
    func partCenter(_ part: OSCPart) -> CGPoint? { rects[part].map { CGPoint(x: $0.midX, y: $0.midY) } }

    /// The area an element covers on screen.
    func elementFrame(_ element: OSCElement) -> CGRect { frame(of: element) }

    // MARK: Touch entry points (called by Moonlight's StreamView)

    @objc(handleTouchDownEvent:)
    func handleTouchDownEvent(_ touches: Set<UITouch>) -> Bool {
        // Any touch, consumed or not, brings a faded gamepad back (after it's been processed, so `holds` is current).
        defer { wake() }
        guard let view else { return false }
        relayout()
        var consumed = false
        for touch in touches where pointerDown(Self.id(touch), at: touch.location(in: view)) { consumed = true }
        return consumed
    }

    @objc(handleTouchMovedEvent:)
    func handleTouchMovedEvent(_ touches: Set<UITouch>) -> Bool {
        defer { wake(rearm: false) }  // moves arrive at display rate; only note the time
        guard let view else { return false }
        var consumed = false
        for touch in touches where pointerMoved(Self.id(touch), at: touch.location(in: view)) { consumed = true }
        return consumed
    }

    @objc(handleTouchUpEvent:)
    func handleTouchUpEvent(_ touches: Set<UITouch>) -> Bool {
        defer { wake() }
        var consumed = false
        for touch in touches where pointerUp(Self.id(touch)) { consumed = true }
        return consumed
    }

    private static func id(_ touch: UITouch) -> Int { Int(bitPattern: ObjectIdentifier(touch)) }

    // MARK: Pointer logic

    /// Returns whether the controls used the touch (so it isn't also sent to the stream as a mouse or touch).
    func pointerDown(_ id: Int, at p: CGPoint) -> Bool {
        if isEditing && !isTrying { return editDown(id, at: p) }
        guard visible else { return false }
        if let part = hit(p) {
            switch part {
            case .up, .down, .left, .right:
                holds[id] = .dpad
                setDpad(direction(at: p))
            case .leftBase, .rightBase:
                let left = part == .leftBase
                holds[id] = .stick(left: left)
                if let last = lastStickRelease[left], Date().timeIntervalSince(last) < Self.stickClickWindow {
                    output?.press(left ? OSCFlag.ls : OSCFlag.rs)
                }
                dragStick(left: left, to: p)
            case .ls, .rs:
                // Toggles, like Moonlight's own: the games that want L3 held don't need a finger parked on it.
                let flag = part == .ls ? OSCFlag.ls : OSCFlag.rs
                if clickToggled.contains(part) {
                    clickToggled.remove(part)
                    output?.release(flag)
                    setPressed(part, false)
                } else {
                    clickToggled.insert(part)
                    output?.press(flag)
                    setPressed(part, true)
                }
                holds[id] = .button(part)
                buzz()
            case .lt:
                output?.leftTrigger(0xFF); holds[id] = .button(part); setPressed(part, true); buzz()
            case .rt:
                output?.rightTrigger(0xFF); holds[id] = .button(part); setPressed(part, true); buzz()
            default:
                output?.press(flag(for: part))
                holds[id] = .button(part)
                setPressed(part, true)
                buzz()
            }
            output?.commit()
            return true
        }
        if isInDeadZone(p) {
            holds[id] = .dead
            return true
        }
        if isFloating, let view {
            // Empty screen: the touch drives a stick under the finger instead of the mouse.
            let left = p.x < view.bounds.midX
            let element: OSCElement = left ? .leftStick : .rightStick
            guard OSCElement.visible(for: level).contains(element), !layout.item(element).hidden else { return false }
            // A second finger on a side whose stick is already out is swallowed, so it neither moves that stick nor clicks the stream.
            guard floatingCenter[left] == nil else { holds[id] = .dead; return true }
            spawnFloatingStick(left: left, at: p, in: view)
            holds[id] = .stick(left: left)
            if let last = lastStickRelease[left], Date().timeIntervalSince(last) < Self.stickClickWindow {
                output?.press(left ? OSCFlag.ls : OSCFlag.rs)
            }
            dragStick(left: left, to: p)
            output?.commit()
            return true
        }
        return false
    }

    /// Puts a stick's base under the finger (kept wholly inside the control area) with the knob at its centre.
    private func spawnFloatingStick(left: Bool, at p: CGPoint, in view: UIView) {
        let element: OSCElement = left ? .leftStick : .rightStick
        let f = sizeFactor(view, item: layout.item(element))
        let area = limit(in: view)
        let extent = union(partRects(element, factor: f))
        var c = p
        c.x = min(max(c.x, area.minX - extent.minX), area.maxX - extent.maxX)
        c.y = min(max(c.y, area.minY - extent.minY), area.maxY - extent.maxY)
        floatingCenter[left] = c
        knobOffset[left] = .zero
        let inner = Self.stickInner * f
        let basePart: OSCPart = left ? .leftBase : .rightBase, knobPart: OSCPart = left ? .leftKnob : .rightKnob
        rects[basePart] = extent.offsetBy(dx: c.x, dy: c.y)
        rects[knobPart] = CGRect(x: c.x - inner / 2, y: c.y - inner / 2, width: inner, height: inner)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for part in [basePart, knobPart] {
            layers[part]?.removeAllAnimations()  // a fade-out from the last release may still be running
            update(part)
        }
        CATransaction.commit()
    }

    /// The stick goes away with the finger: a quick fade, then it's hidden (`isShown` is false once the centre is gone).
    private func removeFloatingStick(left: Bool) {
        floatingCenter[left] = nil
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        layers[left ? .leftBase : .rightBase]?.opacity = 0
        layers[left ? .leftKnob : .rightKnob]?.opacity = 0
        CATransaction.commit()
    }

    /// Whether a floating stick is out on a side, for the self-test.
    func hasFloatingStick(left: Bool) -> Bool { floatingCenter[left] != nil }

    func pointerMoved(_ id: Int, at p: CGPoint) -> Bool {
        guard let hold = holds[id] else { return false }
        switch hold {
        case .drag, .blank: return editMoved(id, at: p)
        case .pinch: return editPinchMoved(id, at: p)
        case .stick(let left):
            dragStick(left: left, to: p)
            output?.commit()
        case .dpad:
            setDpad(direction(at: p))
            output?.commit()
        case .button, .dead:
            break
        }
        return true
    }

    func pointerUp(_ id: Int) -> Bool {
        guard let hold = holds.removeValue(forKey: id) else { return false }
        switch hold {
        case .drag(let element, _):
            editUp(id, dropped: element)
        case .blank:
            editUp(id)
        case .pinch:
            editPinchUp(id)
        case .button(let part):
            switch part {
            case .ls, .rs:
                break
            case .lt:
                output?.leftTrigger(0); setPressed(part, false)
            case .rt:
                output?.rightTrigger(0); setPressed(part, false)
            default:
                output?.release(flag(for: part)); setPressed(part, false)
            }
            output?.commit()
        case .dpad:
            setDpad(nil)
            output?.commit()
        case .stick(let left):
            moveKnob(left: left, to: .zero)
            setPressed(left ? .leftKnob : .rightKnob, false)
            if left { output?.leftStick(x: 0, y: 0); output?.release(OSCFlag.ls) } else { output?.rightStick(x: 0, y: 0); output?.release(OSCFlag.rs) }
            lastStickRelease[left] = Date()
            output?.commit()
            if floatingCenter[left] != nil { removeFloatingStick(left: left) }
        case .dead:
            break
        }
        return true
    }

    /// Lets go of everything, e.g. when the controls hide or the stream ends mid-press.
    func releaseAll() {
        for id in Array(holds.keys) { _ = pointerUp(id) }
        floatingCenter.removeAll()
    }

    private func flag(for part: OSCPart) -> Int32 {
        switch part {
        case .a: OSCFlag.a
        case .b: OSCFlag.b
        case .x: OSCFlag.x
        case .y: OSCFlag.y
        case .up: OSCFlag.up
        case .down: OSCFlag.down
        case .left: OSCFlag.left
        case .right: OSCFlag.right
        case .start: OSCFlag.start
        case .back: OSCFlag.back
        case .lb: OSCFlag.lb
        case .rb: OSCFlag.rb
        default: 0
        }
    }

    private func buzz() {
        guard !isArranging else { return }
        haptic.impactOccurred(intensity: 0.6)
    }

    // MARK: Hit testing

    /// The part under a point. Controls tolerate a finger a little off-target; where two overlap, the nearer wins.
    private func hit(_ p: CGPoint) -> OSCPart? {
        var best: (OSCPart, CGFloat)?
        func consider(_ part: OSCPart, _ distance: CGFloat) {
            if best == nil || distance < best!.1 { best = (part, distance) }
        }
        // A floating stick isn't a target: a finger on it is the one already driving it.
        for (part, rect) in rects where isShown(part.element) && !part.isKnob && !(isFloating && part.element.isStick) {
            let c = CGPoint(x: rect.midX, y: rect.midY)
            let d = hypot(p.x - c.x, p.y - c.y)
            switch part {
            case .up, .down, .left, .right:
                continue  // handled as one cross below
            case .a, .b, .x, .y, .ls, .rs, .leftBase, .rightBase:
                if d <= rect.width / 2 + (part == .leftBase || part == .rightBase ? 6 : 8) { consider(part, d) }
            default:
                if rect.insetBy(dx: -8, dy: -8).contains(p) { consider(part, d) }
            }
        }
        let cluster = frame(of: .dpad)
        if isShown(.dpad), !cluster.isNull, cluster.insetBy(dx: -8, dy: -8).contains(p) {
            let c = CGPoint(x: cluster.midX, y: cluster.midY)
            // The very middle of the cross is dead, as on a real pad.
            if hypot(p.x - c.x, p.y - c.y) > 10 { consider(direction(at: p) ?? .up, hypot(p.x - c.x, p.y - c.y) * 0.5) }
        }
        return best?.0
    }

    private func isInDeadZone(_ p: CGPoint) -> Bool {
        for element in OSCElement.allCases where isShown(element) && !(isFloating && element.isStick) {
            if frame(of: element).insetBy(dx: -Self.deadZonePadding, dy: -Self.deadZonePadding).contains(p) { return true }
        }
        return false
    }

    private func direction(at p: CGPoint) -> OSCPart? {
        let cluster = frame(of: .dpad)
        guard !cluster.isNull else { return nil }
        let dx = p.x - cluster.midX, dy = p.y - cluster.midY
        if hypot(dx, dy) < 8 { return nil }
        return abs(dx) > abs(dy) ? (dx > 0 ? .right : .left) : (dy > 0 ? .down : .up)
    }

    private func setDpad(_ part: OSCPart?) {
        guard part != dpadDirection else { return }
        if let old = dpadDirection { setPressed(old, false) }
        output?.release(OSCFlag.dpad)
        dpadDirection = part
        if let part {
            output?.press(flag(for: part))
            setPressed(part, true)
            buzz()
        }
    }

    private func dragStick(left: Bool, to p: CGPoint) {
        guard let base = rects[left ? .leftBase : .rightBase] else { return }
        let radius = base.width / 2
        var dx = p.x - base.midX, dy = p.y - base.midY
        let distance = hypot(dx, dy)
        if distance > radius { dx *= radius / distance; dy *= radius / distance }
        moveKnob(left: left, to: CGPoint(x: dx, y: dy))
        setPressed(left ? .leftKnob : .rightKnob, true)

        // Radial dead zone, rescaled so the stick still reaches full travel.
        var vx = dx / radius, vy = dy / radius
        let magnitude = hypot(vx, vy)
        if magnitude < Self.stickDeadZone {
            vx = 0; vy = 0
        } else {
            let scaled = (magnitude - Self.stickDeadZone) / (1 - Self.stickDeadZone)
            vx *= scaled / magnitude; vy *= scaled / magnitude
        }
        let x = Int16(max(-0x7FFE, min(0x7FFE, Double(0x7FFE) * vx)))
        let y = Int16(max(-0x7FFE, min(0x7FFE, Double(0x7FFE) * -vy)))
        if left { output?.leftStick(x: x, y: y) } else { output?.rightStick(x: x, y: y) }
    }

    // MARK: Editing

    func setEditing(_ on: Bool) {
        guard on != isEditing else { return }
        if on { releaseAll() }
        isEditing = on
        if !on {
            selected = nil
            isTrying = false
            guides.path = nil
        }
        relayout(force: true)
        onChange?()
    }

    func select(_ element: OSCElement?) {
        selected = element
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateSelection()
        CATransaction.commit()
        onChange?()
    }

    private func updateSelection() {
        guard let view else { return }
        if isArranging {
            if tint.superlayer == nil { view.layer.addSublayer(tint) }
            if overlaps.superlayer == nil { view.layer.addSublayer(overlaps) }
            tint.frame = view.bounds
            overlaps.path = overlapPath()
        } else {
            tint.removeFromSuperlayer()
            overlaps.removeFromSuperlayer()
            overlaps.path = nil
        }
        if isArranging, let selected, !frame(of: selected).isNull {
            if selection.superlayer == nil { view.layer.addSublayer(selection) }
            let f = frame(of: selected).insetBy(dx: -10, dy: -10)
            selection.path = UIBezierPath(roundedRect: f, cornerRadius: 16).cgPath
        } else {
            selection.removeFromSuperlayer()
        }
        if guides.superlayer == nil, isEditing { view.layer.addSublayer(guides) }
    }

    /// Outlines for every pair of shown controls that overlap (by more than a few points, since the shoulder gems'
    /// boxes touch at their default spots). Recomputed whenever the layout is.
    private func overlapPath() -> CGPath {
        let shown = OSCElement.allCases.filter { isShown($0) && !layout.item($0).hidden && !frame(of: $0).isNull }
        // Compare the buttons themselves, not the clusters' bounding boxes: the empty corners of the A B X Y
        // diamond or the D-pad cross would otherwise flag controls that visibly don't touch.
        func buttons(_ element: OSCElement) -> [CGRect] {
            rects.filter { $0.key.element == element && !$0.key.isKnob }.map { $0.value.insetBy(dx: 3, dy: 3) }
        }
        var marked: Set<OSCElement> = []
        for (i, a) in shown.enumerated() {
            let pa = buttons(a)
            for b in shown[(i + 1)...] where pa.contains(where: { r in buttons(b).contains { $0.intersects(r) } }) {
                marked.insert(a)
                marked.insert(b)
            }
        }
        let path = UIBezierPath()
        for element in marked { path.append(UIBezierPath(roundedRect: frame(of: element).insetBy(dx: -4, dy: -4), cornerRadius: 12)) }
        return path.cgPath
    }

    /// Records the bin's frame from a view of the editor chrome (which may be in another window) in the controls' view,
    /// with some slack so the finger doesn't have to be exact.
    func setBin(_ rect: CGRect, in source: UIView) {
        binFrame = view.map { $0.convert(rect, from: source).insetBy(dx: -16, dy: -16) }
    }

    /// Two fingers resizing a control while arranging. Kept from raw pointer ids because the stream view has
    /// its own recognizers, so a UIPinchGestureRecognizer wouldn't see these touches.
    private struct OSCPinch {
        var first: Int, second: Int
        var points: [Int: CGPoint]
        var element: OSCElement
        var startDistance: CGFloat
        var startScale: Double
    }

    private var pinch: OSCPinch?
    /// Last position of each finger that went down while arranging, so a second finger can pair with it.
    private var editPoints: [Int: CGPoint] = [:]
    /// The dragged control as it was when the finger landed, where it goes back to if it is dropped on the bin.
    private var dragOrigin: OSCItem?
    private var dragDown: CGPoint?
    private var dragReported = false

    /// The control under a point, with a little slack for a finger; where frames overlap, the nearest centre wins.
    private func editTarget(at p: CGPoint) -> OSCElement? {
        var best: (OSCElement, CGFloat)?
        for element in OSCElement.allCases {
            let f = frame(of: element).insetBy(dx: -10, dy: -10)
            guard f.contains(p) else { continue }
            let d = hypot(p.x - f.midX, p.y - f.midY)
            if best == nil || d < best!.1 { best = (element, d) }
        }
        return best?.0
    }

    private func editDown(_ id: Int, at p: CGPoint) -> Bool {
        guard holds.isEmpty else { return editSecondFinger(id, at: p) }
        editPoints[id] = p
        guard let element = editTarget(at: p) else {
            select(nil)
            holds[id] = .blank
            return true
        }
        let c = CGPoint(x: frame(of: element).midX, y: frame(of: element).midY)
        holds[id] = .drag(element, grab: CGSize(width: p.x - c.x, height: p.y - c.y))
        dragOrigin = layout.item(element)
        dragDown = p
        dragReported = false
        select(element)
        return true
    }

    /// A finger landing while another is down: with exactly one drag (or empty-space touch) already going it
    /// starts a pinch; anything else is swallowed until it lifts.
    private func editSecondFinger(_ id: Int, at p: CGPoint) -> Bool {
        guard pinch == nil, holds.count == 1, let entry = holds.first, let p1 = editPoints[entry.key] else {
            holds[id] = .dead
            return true
        }
        let element: OSCElement
        switch entry.value {
        case .drag(let dragged, _): element = dragged
        case .blank:
            // No selection to resize: take the control between the two fingers.
            guard let under = editTarget(at: CGPoint(x: (p1.x + p.x) / 2, y: (p1.y + p.y) / 2)) else {
                holds[id] = .dead
                return true
            }
            element = under
        default:
            holds[id] = .dead
            return true
        }
        // Fingers that start nearly together would make the ratio wild, so the baseline has a floor.
        let distance = max(hypot(p.x - p1.x, p.y - p1.y), 40)
        pinch = OSCPinch(first: entry.key, second: id, points: [entry.key: p1, id: p], element: element,
                         startDistance: distance, startScale: layout.item(element).scale)
        holds[entry.key] = .pinch
        holds[id] = .pinch
        guides.path = nil
        if dragReported {
            dragReported = false
            onDragChange?(nil, nil)
        }
        if selected != element { select(element) }
        return true
    }

    private func editPinchMoved(_ id: Int, at p: CGPoint) -> Bool {
        guard var pin = pinch, pin.points[id] != nil else { return true }
        pin.points[id] = p
        pinch = pin
        guard let a = pin.points[pin.first], let b = pin.points[pin.second] else { return true }
        let before = layout.item(pin.element).scale
        setSelectedScale(pin.startScale * Double(hypot(a.x - b.x, a.y - b.y) / pin.startDistance))
        if layout.item(pin.element).scale != before { onChange?() }
        return true
    }

    /// One finger of a pinch lifted: save, and park the other until it lifts so it doesn't start dragging.
    private func editPinchUp(_ id: Int) {
        editPoints[id] = nil
        guard let pin = pinch else { return }
        pinch = nil
        let other = id == pin.first ? pin.second : pin.first
        editPoints[other] = nil
        if holds[other] != nil { holds[other] = .dead }
        persistLayout()
        onChange?()
    }

    private func editMoved(_ id: Int, at p: CGPoint) -> Bool {
        editPoints[id] = p
        guard case .drag(let element, let grab)? = holds[id], let view else { return true }
        let area = limit(in: view)
        let f = sizeFactor(view, item: layout.item(element))
        let extent = union(partRects(element, factor: f))
        var c = CGPoint(x: p.x - grab.width, y: p.y - grab.height)

        // Snap to the centre lines of the other controls and of the screen, and show the line.
        var snapX: CGFloat?, snapY: CGFloat?
        var xs: [CGFloat] = [area.midX], ys: [CGFloat] = [area.midY]
        for other in OSCElement.allCases where other != element && isShown(other) && !layout.item(other).hidden {
            let o = frame(of: other)
            xs.append(o.midX); ys.append(o.midY)
        }
        let threshold: CGFloat = 7
        let ex = (extent.minX + extent.maxX) / 2, ey = (extent.minY + extent.maxY) / 2
        if let x = xs.min(by: { abs($0 - (c.x + ex)) < abs($1 - (c.x + ex)) }), abs(x - (c.x + ex)) < threshold { c.x = x - ex; snapX = x }
        if let y = ys.min(by: { abs($0 - (c.y + ey)) < abs($1 - (c.y + ey)) }), abs(y - (c.y + ey)) < threshold { c.y = y - ey; snapY = y }

        c.x = min(max(c.x, area.minX - extent.minX), area.maxX - extent.maxX)
        c.y = min(max(c.y, area.minY - extent.minY), area.maxY - extent.maxY)

        var item = layout.item(element)
        item.x = Double((c.x - area.minX) / max(1, area.width))
        item.y = Double((c.y - area.minY) / max(1, area.height))
        layout.set(element, item)

        let line = UIBezierPath()
        if let snapX { line.move(to: CGPoint(x: snapX, y: area.minY)); line.addLine(to: CGPoint(x: snapX, y: area.maxY)) }
        if let snapY { line.move(to: CGPoint(x: area.minX, y: snapY)); line.addLine(to: CGPoint(x: area.maxX, y: snapY)) }
        guides.path = line.cgPath
        relayout(force: true)
        if !dragReported, let dragDown, hypot(p.x - dragDown.x, p.y - dragDown.y) > 8 { dragReported = true }
        if dragReported { onDragChange?(element, p) }
        return true
    }

    /// `dropped` is the control this finger was dragging. Lifted with the finger on the bin, it is removed (and goes back
    /// to where it was, so putting it back from the tray doesn't land it on the bin).
    private func editUp(_ id: Int, dropped: OSCElement? = nil) {
        let last = editPoints[id]
        editPoints[id] = nil
        guides.path = nil
        let wasDragged = dragReported
        dragReported = false
        if wasDragged { onDragChange?(nil, nil) }
        if wasDragged, let dropped, let last, let binFrame, binFrame.contains(last), !layout.item(dropped).hidden {
            var item = layout.item(dropped)
            if let origin = dragOrigin { item.x = origin.x; item.y = origin.y }
            item.hidden = true
            layout.set(dropped, item)
            OSCLayoutStore.save(layout)
            relayout(force: true)
            haptic.impactOccurred(intensity: 0.9)
            select(nil)
            return
        }
        OSCLayoutStore.save(layout)
        onChange?()
    }

    /// Dragging the Size slider calls this for every tick, so it only redraws the selected control;
    /// `persistLayout()` saves once the finger lifts. Steps of 2% keep the glass art cache hitting.
    func setSelectedScale(_ scale: Double) {
        guard let selected else { return }
        var item = layout.item(selected)
        let clamped = min(max(scale, OSCLayout.scaleRange.lowerBound), OSCLayout.scaleRange.upperBound)
        item.scale = (clamped / 0.02).rounded() * 0.02
        guard item.scale != layout.item(selected).scale else { return }
        layout.set(selected, item)
        relayout(force: true, only: selected)
    }

    func persistLayout() { OSCLayoutStore.save(layout) }

    func toggleSelectedHidden() {
        guard let selected else { return }
        var item = layout.item(selected)
        item.hidden.toggle()
        layout.set(selected, item)
        OSCLayoutStore.save(layout)
        relayout(force: true)
        onChange?()
    }

    /// The controls the player removed that this level could ever show: the tray's contents.
    var hiddenElements: [OSCElement] {
        let allowed = OSCElement.visible(for: level)
        return OSCElement.allCases.filter { allowed.contains($0) && layout.item($0).hidden }
    }

    /// Puts a removed control back and selects it. It keeps its saved spot unless that now sits on another
    /// control (the player may have filled the gap), in which case it goes back to its default position.
    func restore(_ element: OSCElement) {
        var item = layout.item(element)
        guard item.hidden else { return }
        item.hidden = false
        let allowed = OSCElement.visible(for: level)
        let mine = frame(of: element)
        let covered = !mine.isNull && OSCElement.allCases.contains { other in
            other != element && allowed.contains(other) && !layout.item(other).hidden
                && mine.intersects(frame(of: other).insetBy(dx: 4, dy: 4))
        }
        if covered {
            item.x = element.defaultPosition.x
            item.y = element.defaultPosition.y
        }
        layout.set(element, item)
        OSCLayoutStore.save(layout)
        relayout(force: true)
        select(element)
    }

    /// Opacity is a single layer property, so nothing is redrawn; it's saved by `persistLayout()`.
    func setOpacity(_ opacity: Double) {
        layout.opacity = min(max(opacity, OSCLayout.opacityRange.lowerBound), OSCLayout.opacityRange.upperBound)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if !isFaded { root.opacity = Float(layout.opacity) }
        CATransaction.commit()
    }

    /// Floating sticks on or off (the Controls panel's switch). Saved at once; the runtime reads `layout.floatingSticks`.
    func setFloatingSticks(_ on: Bool) {
        guard on != layout.floatingSticks else { return }
        releaseAll()
        layout.floatingSticks = on
        OSCLayoutStore.save(layout)
        relayout(force: true)
        onChange?()
    }

    /// Seconds of idle before the controls fade (0 = never). Saved at once; the runtime reads `layout.fadeAfter`.
    func setFadeAfter(_ seconds: Double) {
        guard seconds != layout.fadeAfter else { return }
        layout.fadeAfter = seconds
        OSCLayoutStore.save(layout)
        wake()  // restores full opacity when it's now 0, and restarts the idle timer
        onChange?()
    }

    // MARK: Fade after idle

    /// Notes a touch (or a settings change): brings a faded gamepad back quickly and restarts the idle timer.
    /// `rearm: false` is for touch moves, which only need the time noted.
    func wake(rearm: Bool = true) {
        lastTouch = CACurrentMediaTime()
        if isFaded {
            isFaded = false
            animateRootOpacity(Float(layout.opacity), duration: 0.15)
        }
        if rearm || fadeTask == nil { armFade() }
    }

    /// Waits out the idle time, then fades. While a finger is held the wait just repeats, so a long hold never fades it.
    private func armFade() {
        fadeTask?.cancel()
        fadeTask = nil
        guard layout.fadeAfter > 0, visible, !isEditing, !isFaded else { return }
        let wait = holds.isEmpty ? max(0.05, lastTouch + layout.fadeAfter - CACurrentMediaTime()) : layout.fadeAfter
        fadeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.fadeTask = nil
            if self.holds.isEmpty, CACurrentMediaTime() - self.lastTouch >= self.layout.fadeAfter { self.fadeOut() } else { self.armFade() }
        }
    }

    /// Fades the whole gamepad out. Does nothing while a finger is held, while editing, or when fading is off.
    func fadeOut() {
        guard layout.fadeAfter > 0, visible, !isEditing, holds.isEmpty, !isFaded else { return }
        isFaded = true
        animateRootOpacity(0, duration: 0.4)
    }

    /// Sets the model value at once and animates from where the layer currently looks, so a half-done fade reverses smoothly.
    private func animateRootOpacity(_ value: Float, duration: CFTimeInterval) {
        let from = root.presentation()?.opacity ?? root.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.opacity = value
        CATransaction.commit()
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = value
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        root.add(animation, forKey: "idleFade")
    }

    func resetLayout() {
        layout = OSCLayout()
        OSCLayoutStore.save(layout)
        knobOffset.removeAll()
        relayout(force: true)
        onChange?()
    }

    /// Reloads the saved layout (another screen may have changed it).
    func reloadLayout() {
        layout = OSCLayoutStore.load()
        relayout(force: true)
    }

    // MARK: In-stream editing

    /// Shows the editor chrome over the running stream. The stream sees nothing while it's open.
    private func beginStreamEditing() {
        guard !isEditing, let scene = view?.window?.windowScene else { return }
        setEditing(true)
        let host = UIViewController()
        host.view.backgroundColor = .clear
        let panel = OSCEditorPanel(controls: self, showsTryIt: false) { [weak self] in self?.endStreamEditing() }
        panel.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(panel)
        // The chrome fills the window and passes touches through everywhere except on its own pieces (see `PanelWindow`).
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: host.view.topAnchor),
            panel.bottomAnchor.constraint(equalTo: host.view.bottomAnchor),
            panel.leadingAnchor.constraint(equalTo: host.view.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: host.view.trailingAnchor),
        ])
        let window = PanelWindow(windowScene: scene)
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 2)
        window.backgroundColor = .clear
        window.rootViewController = host
        // Shown without becoming key, so Moonlight keeps keyboard and controller input.
        window.isHidden = false
        panelWindow = window
    }

    private func endStreamEditing() {
        panelWindow?.isHidden = true
        panelWindow = nil
        setEditing(false)
    }
}

/// Takes touches on the editor chrome's pieces only; everything else falls through to the stream below.
private final class PanelWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === rootViewController?.view ? nil : hit
    }
}

private extension OSCElement {
    var isStick: Bool { self == .leftStick || self == .rightStick }
}

private extension OSCPart {
    var isKnob: Bool { self == .leftKnob || self == .rightKnob }
}
