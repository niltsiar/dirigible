// Post HID events (the path of a real mouse, trackpad, or keyboard) at the Dirigible window, for
// app checks in the verify phase. Start the app first with `make run`.
// The terminal app needs the Accessibility permission, and the screen must be unlocked.
// Points are from the top-left corner of the window. Each event waits 20 ms.
//
// usage: hid.swift drag <x> <y> <dx> <dy> [--no-up]   a left drag in 20 steps, then the up
//        hid.swift up <x> <y>                         a left mouse-up (after drag --no-up)
//        hid.swift click <x> <y> [--right] [--double] a click (a right click; a double-click)
//        hid.swift key <code> [--command] [--shift] [--option] [--dry-run]
//                                                     a key down and up (53 = Esc, 6 = Z), with the
//                                                     modifier keys down before it and up after it
//        hid.swift scroll <x> <y> <dx> <dy> [--phases] one wheel event at the point; with
//                                                     --phases a trackpad gesture of 10 events
//                                                     with scroll phases and 10 momentum events
// A key event with a modifier flag and no modifier key left the system modifier held: every later
// CGEvent of any process took it (run 1b Phase 7: the wheel of two tests became a Command-wheel).
// --dry-run prints the key events and posts nothing.
// Exit: 0 posted, 1 no Dirigible window, 2 usage, 3 no Accessibility trust.
import ApplicationServices
import CoreGraphics
import Foundation

let usage = """
    usage: hid.swift drag <x> <y> <dx> <dy> [--no-up]
           hid.swift up <x> <y>
           hid.swift click <x> <y> [--right] [--double]
           hid.swift key <code> [--command] [--shift] [--option] [--dry-run]
           hid.swift scroll <x> <y> <dx> <dy> [--phases]

    """

func fail(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let arguments = Array(CommandLine.arguments.dropFirst())
let flags = Set(arguments.filter { $0.hasPrefix("--") })
let known: Set = ["--no-up", "--right", "--double", "--command", "--shift", "--option", "--dry-run", "--phases"]
guard flags.isSubset(of: known) else { fail(usage, 2) }
let words = arguments.filter { !$0.hasPrefix("--") }
guard let command = words.first else { fail(usage, 2) }
let numbers = words.dropFirst().map(Double.init)
guard numbers.allSatisfy({ $0 != nil }) else { fail(usage, 2) }
let values = numbers.compactMap { $0 }
let counts = ["drag": 4, "up": 2, "click": 2, "key": 1, "scroll": 4]
guard let count = counts[command], values.count == count else { fail(usage, 2) }

// The key events: each modifier key down, the key down and up, each modifier key up.
let modifiers: [(flag: String, code: CGKeyCode, mask: CGEventFlags)] = [
    ("--command", 55, .maskCommand), ("--shift", 56, .maskShift), ("--option", 58, .maskAlternate),
]
var keyEvents: [(code: CGKeyCode, down: Bool, mask: CGEventFlags)] = []
if command == "key" {
    let held = modifiers.filter { flags.contains($0.flag) }
    var mask: CGEventFlags = []
    for modifier in held {
        mask.insert(modifier.mask)
        keyEvents.append((modifier.code, true, mask))
    }
    keyEvents += [(CGKeyCode(values[0]), true, mask), (CGKeyCode(values[0]), false, mask)]
    for modifier in held.reversed() {
        mask.remove(modifier.mask)
        keyEvents.append((modifier.code, false, mask))
    }
    if flags.contains("--dry-run") {
        for event in keyEvents { print("\(event.down ? "down" : "up") \(event.code) flags \(event.mask.rawValue)") }
        exit(0)
    }
}

guard AXIsProcessTrusted() else {
    fail("No Accessibility trust. Add the terminal app in System Settings > Privacy & Security > Accessibility.", 3)
}

func wait20ms() { usleep(20_000) }

if command == "key" {
    for key in keyEvents {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: key.code, keyDown: key.down)
        event?.flags = key.mask
        event?.post(tap: .cghidEventTap)
        wait20ms()
    }
    exit(0)
}

let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
guard let window = windows.first(where: { $0[kCGWindowOwnerName as String] as? String == "Dirigible" }),
    let bounds = window[kCGWindowBounds as String] as? [String: Double], let left = bounds["X"], let top = bounds["Y"]
else { fail("No Dirigible window on screen. Run make run first.", 1) }
let origin = CGPoint(x: left + values[0], y: top + values[1])

func mouse(_ type: CGEventType, _ point: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
    wait20ms()
}

switch command {
case "drag":
    mouse(.mouseMoved, origin)
    mouse(.leftMouseDown, origin)
    let end = CGPoint(x: origin.x + values[2], y: origin.y + values[3])
    for step in 1...20 {
        let t = Double(step) / 20
        mouse(.leftMouseDragged, CGPoint(x: origin.x + values[2] * t, y: origin.y + values[3] * t))
    }
    if !flags.contains("--no-up") { mouse(.leftMouseUp, end) }
case "up":
    mouse(.leftMouseUp, origin)
case "click":
    mouse(.mouseMoved, origin)
    let right = flags.contains("--right")
    for clicks in flags.contains("--double") ? [1, 2] : [1] {
        for type: CGEventType in right ? [.rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp] {
            let event = CGEvent(
                mouseEventSource: nil, mouseType: type, mouseCursorPosition: origin, mouseButton: right ? .right : .left
            )
            event?.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
            event?.post(tap: .cghidEventTap)
            wait20ms()
        }
    }
default:  // scroll
    mouse(.mouseMoved, origin)
    func wheel(_ dx: Double, _ dy: Double, phase: Int64, momentum: Int64) {
        let event = CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx),
            wheel3: 0)
        event?.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        event?.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        event?.post(tap: .cghidEventTap)
        wait20ms()
    }
    guard flags.contains("--phases") else {
        wheel(values[2], values[3], phase: 0, momentum: 0)
        break
    }
    // Scroll phases: 1 began, 2 changed, 4 ended. Momentum phases: 1 begin, 2 continue, 3 end.
    for step in 0..<10 { wheel(values[2] / 10, values[3] / 10, phase: step == 0 ? 1 : 2, momentum: 0) }
    wheel(0, 0, phase: 4, momentum: 0)
    for step in 0..<10 {
        let decay = Double(10 - step) / 20
        wheel(values[2] / 10 * decay, values[3] / 10 * decay, phase: 0, momentum: step == 0 ? 1 : 2)
    }
    wheel(0, 0, phase: 0, momentum: 3)
}
