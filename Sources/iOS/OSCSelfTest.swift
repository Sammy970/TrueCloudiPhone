import UIKit

#if DEBUG
/// Checks the on-screen controls' input logic without a screen or real touches (the Simulator can't synthesise
/// them): feed pointer events straight in and read what comes out. Run with `TRUECLOUD_PREVIEW=controls:selftest`;
/// results go to the log as `[osc-selftest] PASS/FAIL …`.
@MainActor
enum OSCSelfTest {
    @discardableResult
    static func run() -> Bool {
        let saved = OSCLayoutStore.load()
        defer { OSCLayoutStore.save(saved) }
        OSCLayoutStore.save(OSCLayout())

        var failures: [String] = []
        func check(_ name: String, _ ok: Bool) {
            Log.info("[osc-selftest] \(ok ? "PASS" : "FAIL") \(name)")
            if !ok { failures.append(name) }
        }

        let view = UIView(frame: CGRect(x: 0, y: 0, width: 874, height: 402))
        let out = OSCRecordingOutput()
        let c = TrueCloudOnScreenControls(view: view, output: out, swapABXY: false)
        c.setLevel(.full)
        c.show()
        c.relayout(force: true)
        func at(_ part: OSCPart) -> CGPoint { c.partCenter(part) ?? .zero }

        // Buttons
        check("A sends A and releases", c.pointerDown(1, at: at(.a)) && out.flags & OSCFlag.a != 0 && c.pointerUp(1) && out.flags == 0)
        check("B, X, Y send their own flags",
              [(OSCPart.b, OSCFlag.b), (.x, OSCFlag.x), (.y, OSCFlag.y), (.lb, OSCFlag.lb), (.rb, OSCFlag.rb), (.start, OSCFlag.start), (.back, OSCFlag.back)].allSatisfy { part, flag in
                  let ok = c.pointerDown(2, at: at(part)) && out.flags == flag
                  _ = c.pointerUp(2)
                  return ok && out.flags == 0
              })
        check("Two buttons at once", c.pointerDown(3, at: at(.a)) && c.pointerDown(4, at: at(.b)) && out.flags == (OSCFlag.a | OSCFlag.b))
        _ = c.pointerUp(3); _ = c.pointerUp(4)
        check("Both released", out.flags == 0)

        // Triggers
        check("LT and RT go to full", c.pointerDown(5, at: at(.lt)) && out.lt == 255 && c.pointerDown(6, at: at(.rt)) && out.rt == 255)
        _ = c.pointerUp(5); _ = c.pointerUp(6)
        check("Triggers release", out.lt == 0 && out.rt == 0)

        // D-pad: press up, slide to right, let go
        check("D-pad up", c.pointerDown(7, at: at(.up)) && out.flags == OSCFlag.up)
        check("D-pad slides to right", c.pointerMoved(7, at: at(.right)) && out.flags == OSCFlag.right)
        _ = c.pointerUp(7)
        check("D-pad releases", out.flags == 0)

        // Sticks
        c.simulateStick(left: true, dx: 1, dy: 0, id: 8)
        check("Left stick full right", out.lx >= 0x7FF0 && out.ly == 0)
        _ = c.pointerUp(8)
        check("Left stick recentres", out.lx == 0 && out.ly == 0)
        c.simulateStick(left: false, dx: 0, dy: -1, id: 9)
        check("Right stick full up", out.ry >= 0x7FF0 && out.rx == 0)
        _ = c.pointerUp(9)
        c.simulateStick(left: true, dx: 0.05, dy: 0.05, id: 10)
        check("Dead zone ignores a nudge", out.lx == 0 && out.ly == 0)
        _ = c.pointerUp(10)
        c.simulateStick(left: true, dx: 0.5, dy: 0, id: 11)
        check("Half travel is roughly half", out.lx > 0x2000 && out.lx < 0x5000)
        _ = c.pointerUp(11)

        // Stick click buttons toggle
        _ = c.pointerDown(12, at: at(.ls)); _ = c.pointerUp(12)
        check("LS click turns on", out.flags & OSCFlag.ls != 0)
        _ = c.pointerDown(13, at: at(.ls)); _ = c.pointerUp(13)
        check("LS click turns off", out.flags & OSCFlag.ls == 0)

        // Touches near controls are swallowed; far ones go to the stream
        let face = c.elementFrame(.face)
        check("Touch beside a control is swallowed, sends nothing",
              c.pointerDown(14, at: CGPoint(x: face.minX + 3, y: face.minY + 3)) && out.flags == 0)
        _ = c.pointerUp(14)
        check("Touch on empty screen goes through", !c.pointerDown(15, at: CGPoint(x: 437, y: 150)))

        // Levels
        c.setLevel(.simple)
        check("Simple level has no triggers", !c.pointerDown(16, at: at(.lt)) && out.lt == 0)
        check("Simple level still has A", c.pointerDown(17, at: at(.a)) && out.flags & OSCFlag.a != 0)
        _ = c.pointerUp(17)
        c.setLevel(.autoGCExtendedGamepadWithStickButtons)
        check("Extended-gamepad level has only Start and Back", !c.pointerDown(18, at: at(.a)) && c.pointerDown(19, at: at(.start)))
        _ = c.pointerUp(19)
        c.setLevel(.full)

        // Swapped A/B/X/Y
        let swapped = TrueCloudOnScreenControls(view: view, output: OSCRecordingOutput(), swapABXY: true)
        swapped.setLevel(.full); swapped.show(); swapped.relayout(force: true)
        check("Swapped layout puts A on the right and B below",
              (swapped.partCenter(.a)?.x ?? 0) > (swapped.partCenter(.b)?.x ?? 1) && (swapped.partCenter(.b)?.y ?? 0) > (swapped.partCenter(.a)?.y ?? 1))

        // Editing: nothing is sent, controls move, and the layout is saved
        let aCenter = at(.a)
        c.setEditing(true)
        check("Editing doesn't send presses", c.pointerDown(20, at: at(.a)) && out.flags == 0)
        _ = c.pointerUp(20)
        check("Pressing selects the control", c.selected == .face)
        let before = c.layout.item(.leftStick)
        let stickCenter = at(.leftBase)
        _ = c.pointerDown(21, at: stickCenter)
        _ = c.pointerMoved(21, at: CGPoint(x: stickCenter.x + 90, y: stickCenter.y - 70))
        _ = c.pointerUp(21)
        let after = c.layout.item(.leftStick)
        check("Dragging moves the stick", after.x > before.x && after.y < before.y)
        check("The move is saved", OSCLayoutStore.load().item(.leftStick) == after)
        c.setSelectedScale(1.5)
        check("Resizing is saved", OSCLayoutStore.load().item(.leftStick).scale == 1.5)
        c.select(.face)
        c.toggleSelectedHidden()
        check("Hiding is saved", OSCLayoutStore.load().item(.face).hidden)
        c.setEditing(false)
        check("A hidden control doesn't respond", !c.pointerDown(22, at: aCenter) && out.flags == 0)
        _ = c.pointerUp(22)
        c.setEditing(true)
        c.isTrying = true
        c.setEditing(false)
        c.resetLayout()
        check("Reset restores the defaults", c.layout.isDefault && OSCLayoutStore.load().isDefault)

        // Layout survives a trip through storage
        var layout = OSCLayout()
        layout.opacity = 0.5
        layout.set(.dpad, OSCItem(x: 0.3, y: 0.6, scale: 1.2, hidden: false))
        OSCLayoutStore.save(layout)
        check("Layout round-trips", OSCLayoutStore.load() == layout)

        Log.info("[osc-selftest] \(failures.isEmpty ? "ALL PASSED" : "\(failures.count) FAILED: \(failures.joined(separator: "; "))")")
        return failures.isEmpty
    }
}
#endif
