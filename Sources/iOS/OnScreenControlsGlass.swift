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

    // Editing
    private(set) var isEditing = false
    private(set) var selected: OSCElement?
    /// Called when the selection or layout changes, so an editor panel can refresh.
    var onChange: (() -> Void)?
    /// In-stream editing: the panel shown over the stream.
    private var panel: UIView?
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
        root.removeFromSuperlayer()
        selection.removeFromSuperlayer()
        guides.removeFromSuperlayer()
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

    private func isShown(_ element: OSCElement) -> Bool {
        if isArranging { return true }
        return OSCElement.visible(for: level).contains(element) && !layout.item(element).hidden
    }

    /// Positions every control. Cheap enough to call whenever the size, level or layout changes.
    func relayout(force: Bool = false) {
        guard let view else { return }
        if !force, view.bounds == lastBounds, view.safeAreaInsets == lastInsets { return }
        lastBounds = view.bounds
        lastInsets = view.safeAreaInsets
        screenScale = view.window?.windowScene?.screen.scale ?? view.traitCollection.displayScale
        if screenScale < 1 { screenScale = 3 }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.frame = view.bounds
        root.opacity = isArranging ? 1 : Float(layout.opacity)
        rects.removeAll()
        for element in OSCElement.allCases {
            let c = center(of: element, in: view)
            let f = sizeFactor(view, item: layout.item(element))
            for (part, r) in partRects(element, factor: f) { rects[part] = r.offsetBy(dx: c.x, dy: c.y) }
            if element == .leftStick || element == .rightStick, let base = rects[element == .leftStick ? .leftBase : .rightBase] {
                let inner = Self.stickInner * f
                let isLeft = element == .leftStick
                let o = knobOffset[isLeft] ?? .zero
                rects[isLeft ? .leftKnob : .rightKnob] = CGRect(x: base.midX + o.x - inner / 2, y: base.midY + o.y - inner / 2, width: inner, height: inner)
            }
        }
        for part in OSCPart.allCases { update(part) }
        updateSelection()
        CATransaction.commit()
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
        guard let view else { return false }
        relayout()
        var consumed = false
        for touch in touches where pointerDown(Self.id(touch), at: touch.location(in: view)) { consumed = true }
        return consumed
    }

    @objc(handleTouchMovedEvent:)
    func handleTouchMovedEvent(_ touches: Set<UITouch>) -> Bool {
        guard let view else { return false }
        var consumed = false
        for touch in touches where pointerMoved(Self.id(touch), at: touch.location(in: view)) { consumed = true }
        return consumed
    }

    @objc(handleTouchUpEvent:)
    func handleTouchUpEvent(_ touches: Set<UITouch>) -> Bool {
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
        return false
    }

    func pointerMoved(_ id: Int, at p: CGPoint) -> Bool {
        guard let hold = holds[id] else { return false }
        switch hold {
        case .drag: return editMoved(id, at: p)
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
        case .drag:
            editUp()
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
        case .dead:
            break
        }
        return true
    }

    /// Lets go of everything, e.g. when the controls hide or the stream ends mid-press.
    func releaseAll() {
        for id in Array(holds.keys) { _ = pointerUp(id) }
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
        for (part, rect) in rects where isShown(part.element) && !part.isKnob {
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
        for element in OSCElement.allCases where isShown(element) {
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
        if isArranging, let selected, !frame(of: selected).isNull {
            if selection.superlayer == nil { view.layer.addSublayer(selection) }
            let f = frame(of: selected).insetBy(dx: -10, dy: -10)
            selection.path = UIBezierPath(roundedRect: f, cornerRadius: 16).cgPath
        } else {
            selection.removeFromSuperlayer()
        }
        if guides.superlayer == nil, isEditing { view.layer.addSublayer(guides) }
    }

    private func editDown(_ id: Int, at p: CGPoint) -> Bool {
        guard holds.isEmpty else { return true }
        var best: (OSCElement, CGFloat)?
        for element in OSCElement.allCases {
            let f = frame(of: element).insetBy(dx: -10, dy: -10)
            guard f.contains(p) else { continue }
            let d = hypot(p.x - f.midX, p.y - f.midY)
            if best == nil || d < best!.1 { best = (element, d) }
        }
        guard let element = best?.0 else {
            select(nil)
            return true
        }
        let c = CGPoint(x: frame(of: element).midX, y: frame(of: element).midY)
        holds[id] = .drag(element, grab: CGSize(width: p.x - c.x, height: p.y - c.y))
        select(element)
        return true
    }

    private func editMoved(_ id: Int, at p: CGPoint) -> Bool {
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
        return true
    }

    private func editUp() {
        guides.path = nil
        OSCLayoutStore.save(layout)
        onChange?()
    }

    func setSelectedScale(_ scale: Double) {
        guard let selected else { return }
        var item = layout.item(selected)
        item.scale = min(max(scale, OSCLayout.scaleRange.lowerBound), OSCLayout.scaleRange.upperBound)
        layout.set(selected, item)
        OSCLayoutStore.save(layout)
        relayout(force: true)
    }

    func toggleSelectedHidden() {
        guard let selected else { return }
        var item = layout.item(selected)
        item.hidden.toggle()
        layout.set(selected, item)
        OSCLayoutStore.save(layout)
        relayout(force: true)
        onChange?()
    }

    func setOpacity(_ opacity: Double) {
        layout.opacity = min(max(opacity, OSCLayout.opacityRange.lowerBound), OSCLayout.opacityRange.upperBound)
        OSCLayoutStore.save(layout)
        relayout(force: true)
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

    /// Shows the editor panel over the running stream. The stream sees nothing while it's open.
    private func beginStreamEditing() {
        guard !isEditing, let view else { return }
        setEditing(true)
        let panel = OSCEditorPanel(controls: self, showsTryIt: false) { [weak self] in self?.endStreamEditing() }
        panel.layer.zPosition = 2000
        view.addSubview(panel)
        panel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            panel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
            panel.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            panel.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -40),
        ])
        self.panel = panel
    }

    private func endStreamEditing() {
        panel?.removeFromSuperview()
        panel = nil
        setEditing(false)
    }
}

private extension OSCPart {
    var isKnob: Bool { self == .leftKnob || self == .rightKnob }
}
