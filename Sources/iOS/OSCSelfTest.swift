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

        // Floating sticks: empty-screen touches drive the sticks under the finger instead of the stream
        /// An empty spot (not on a control, not in a dead zone) in one half, nearest a target, found with floating off.
        func emptySpot(left: Bool) -> CGPoint {
            let target = CGPoint(x: left ? 220 : 660, y: 200)
            var best = target, bestDistance = CGFloat.greatestFiniteMagnitude
            for x in stride(from: left ? 40 : 450, through: left ? 420 : 840, by: 10) {
                for y in stride(from: 60, through: 340, by: 10) {
                    let p = CGPoint(x: x, y: y)
                    let used = c.pointerDown(900, at: p)
                    if used { _ = c.pointerUp(900) }
                    let d = hypot(p.x - target.x, p.y - target.y)
                    if !used, d < bestDistance { best = p; bestDistance = d }
                }
            }
            return best
        }
        let leftEmpty = emptySpot(left: true), rightEmpty = emptySpot(left: false)
        let fixedLeftStick = at(.leftBase)
        check("Floating off: empty touch gives no stick output", !c.pointerDown(30, at: leftEmpty) && out.lx == 0 && !c.hasFloatingStick(left: true))
        c.setFloatingSticks(true)
        let spawnedDown = c.pointerDown(31, at: leftEmpty)
        let spawnedAt = c.partCenter(.leftBase) ?? .zero
        let underFinger = abs(spawnedAt.x - leftEmpty.x) < 0.5 && abs(spawnedAt.y - leftEmpty.y) < 0.5
        check("Floating: empty left touch is consumed and spawns the left stick under the finger",
              spawnedDown && underFinger && c.hasFloatingStick(left: true) && !c.hasFloatingStick(left: false))
        _ = c.pointerMoved(31, at: CGPoint(x: leftEmpty.x + 200, y: leftEmpty.y))
        check("Floating: dragging the left stick moves only the left output", out.lx > 0x6000 && out.rx == 0 && out.ry == 0)
        check("Floating: a second finger on the same side is swallowed", c.pointerDown(32, at: CGPoint(x: leftEmpty.x + 5, y: leftEmpty.y + 5)))
        check("Floating: the second finger doesn't move the stick", out.lx > 0x6000)
        _ = c.pointerUp(32)
        check("Floating: both sides at once", c.pointerDown(33, at: rightEmpty) && c.hasFloatingStick(left: true) && c.hasFloatingStick(left: false))
        _ = c.pointerMoved(33, at: CGPoint(x: rightEmpty.x, y: rightEmpty.y - 200))
        check("Floating: dragging the right stick moves only the right output", out.ry > 0x6000 && out.lx > 0x6000)
        _ = c.pointerUp(33)
        check("Floating: lifting zeroes the right stick and removes it", out.rx == 0 && out.ry == 0 && !c.hasFloatingStick(left: false) && c.hasFloatingStick(left: true))
        _ = c.pointerUp(31)
        check("Floating: lifting zeroes the left stick and removes it", out.lx == 0 && out.ly == 0 && !c.hasFloatingStick(left: true))
        check("Floating: a fixed control still wins and spawns nothing",
              c.pointerDown(34, at: at(.a)) && out.flags & OSCFlag.a != 0 && !c.hasFloatingStick(left: false) && !c.hasFloatingStick(left: true))
        _ = c.pointerUp(34)
        check("Floating: the fixed stick isn't hit", c.pointerDown(35, at: CGPoint(x: fixedLeftStick.x + 50, y: fixedLeftStick.y)) && out.lx == 0)
        _ = c.pointerUp(35)
        check("Floating: releaseAll clears a floating stick", c.pointerDown(36, at: leftEmpty) && c.hasFloatingStick(left: true))
        c.releaseAll()
        check("Floating: releaseAll removed it", !c.hasFloatingStick(left: true) && out.lx == 0)
        c.setFloatingSticks(false)
        check("Floating off again: empty touch goes to the stream", !c.pointerDown(37, at: leftEmpty) && out.lx == 0)

        // Fade after idle
        c.setFadeAfter(5)
        check("Fade: not faded to begin with", !c.isFaded)
        _ = c.pointerDown(38, at: at(.a))
        c.fadeOut()
        check("Fade: never while a finger is held", !c.isFaded)
        _ = c.pointerUp(38)
        c.fadeOut()
        check("Fade: fades when idle", c.isFaded)
        check("Fade: a faded control still presses", c.pointerDown(39, at: at(.a)) && out.flags & OSCFlag.a != 0)
        _ = c.pointerUp(39)
        c.wake()
        check("Fade: a touch brings it back", !c.isFaded)
        c.fadeOut()
        c.setFadeAfter(0)
        check("Fade: turning it off restores the controls", !c.isFaded)
        c.fadeOut()
        check("Fade: off means never", !c.isFaded)

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
        c.persistLayout()  // the slider saves once the finger lifts, not on every tick
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
