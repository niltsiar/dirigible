// Post HID events (the path of a real mouse, trackpad, or keyboard) at the Dirigible window, for
// app checks in the verify phase. Start the app first with `make run`.
// The terminal app needs the Accessibility permission, and the screen must be unlocked.
// Points are from the top-left corner of the window. Each event waits 20 ms.
// The target app has the bundle ID in DIRIGIBLE_BUNDLE_ID (default com.delineas.dirigible; the
// verify copy is com.delineas.dirigible.verify). Before each burst of events (a key with its
// modifier keys, a typed character, a click, a drag, a scroll), the script activates the target
// app and waits up to 2 s until its PID is frontmost. Else it posts nothing more and exits 4. A
// HID event goes to the frontmost app: the verify copy once opened behind the terminal, and the
// keys and the text of a check went to the terminal (run 2026-10-04-hid-front). An up has no
// check: a held left button after a failed drag is worse than an up in another app. A bare up,
// or an up with no target window, goes to the pointer location.
//
// usage: run it with no command. The table `verbs` gives the arguments and the flags of each verb.
//        drag: a left drag in 20 steps, then the up (--no-up: no up). --outside: the start point
//              may be outside the target window, in a Finder window in front (a drag of a file
//              from the Finder), and the end point must be in the target window
//        up: a left mouse-up (after drag --no-up)
//        click: a click (--right: a right click; --double: a double-click)
//        move: a mouse move with no button
//        key: a key down and up (53 = Esc, 6 = Z)
//        type: the text, one key down and up for each character, with no modifier; a word that
//              starts with "--" is a flag, not text; no newline or tab (use key 36 or key 48)
//        scroll: one mouse wheel event in lines at the point; with --phases a trackpad gesture of
//                10 events in pixels with scroll phases and 10 momentum events (macOS makes Shift
//                with the wheel a horizontal scroll only for lines)
//        Each point is from the top-left corner of the window, also for up. A modifier flag
//        (--command, --shift, --option, --control) holds its key down around the events.
// A key event with a modifier flag and no modifier key left the system modifier held: every later
// CGEvent of any process took it (run 1b Phase 7: the wheel of two tests became a Command-wheel).
// --dry-run prints the key, text, and wheel events, the origin of an up (`up pointer|window
// <x> <y>`), and the screen start and end of a drag (`drag <x0> <y0> to <x1> <y1>`). It posts
// nothing and needs no target app. A drag dry run reads the windows from HID_TEST_WINDOWS, front
// to back, as `owner x y w h` groups in screen points; the owner `target` is the target app.
// Exit: 0 posted, 1 no Dirigible window, 2 usage or an empty DIRIGIBLE_BUNDLE_ID, 3 no
// Accessibility trust, 4 the target app is not frontmost (it does not run, more than one app has
// the bundle ID, or it did not come to the front in 2 s), 5 the point of a click, a drag start,
// or a scroll is outside the target window; with drag --outside, the end is outside the target
// window, or the frontmost window at layer 0 or above at the start is not a Finder window.
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// The arguments, the count of numbers, and the flags of each verb. The usage text and the checks
/// come from this table.
let modifierFlags = ["--command", "--shift", "--option", "--control"]
let verbs: [(verb: String, arguments: String, count: Int, flags: [String])] = [
    ("drag", "<x> <y> <dx> <dy>", 4, ["--no-up", "--outside"] + modifierFlags + ["--dry-run"]),
    ("up", "[<x> <y>]", 2, ["--dry-run"]),
    ("click", "<x> <y>", 2, ["--right", "--double"] + modifierFlags),
    ("move", "<x> <y>", 2, []),
    ("key", "<code>", 1, modifierFlags + ["--dry-run"]),
    ("type", "<text>", 0, ["--dry-run"]),
    ("scroll", "<x> <y> <dx> <dy>", 4, ["--phases"] + modifierFlags + ["--dry-run"]),
]
let usage =
    "usage: "
    + verbs.map { "hid.swift \($0.verb) \($0.arguments)" + $0.flags.map { " [\($0)]" }.joined() }
    .joined(separator: "\n       ") + "\n"

func fail(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let arguments = Array(CommandLine.arguments.dropFirst())
let flags = Set(arguments.filter { $0.hasPrefix("--") })
let words = arguments.filter { !$0.hasPrefix("--") }
guard let command = words.first, let verb = verbs.first(where: { $0.verb == command }), flags.isSubset(of: verb.flags)
else { fail(usage, 2) }
let text = command == "type" ? words.dropFirst().joined(separator: " ") : ""
let badText = text.isEmpty || text.contains(where: \.isNewline) || text.contains("\t")
if command == "type", badText { fail(usage, 2) }
let numbers = command == "type" ? [] : words.dropFirst().map(Double.init)
guard numbers.allSatisfy({ $0 != nil }) else { fail(usage, 2) }
let values = numbers.compactMap { $0 }
guard values.count == verb.count || (command == "up" && values.isEmpty) else {
    fail(usage, 2)
}
let bundleID = ProcessInfo.processInfo.environment["DIRIGIBLE_BUNDLE_ID"] ?? "com.delineas.dirigible"
if bundleID.isEmpty { fail("DIRIGIBLE_BUNDLE_ID is empty. Unset it, or give a bundle ID.", 2) }

/// Waits and lets the run loop run, so that the frontmost app of NSWorkspace stays current.
func wait(_ seconds: Double) { RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds)) }
func wait20ms() { wait(0.02) }

/// The running apps with the bundle ID. The apps of two trees can share it.
func runningTargets() -> [NSRunningApplication] {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
}

/// Brings the target app to the front, or exits 4. Call it before each burst of events, never
/// between a modifier key down and its up. `posted` is the count of characters that `type`
/// posted before this check.
@discardableResult
func requireFront(posted: Int = 0) -> NSRunningApplication {
    let notFront = "The target app is not frontmost: \(bundleID)"
    let done = posted == 0 ? "Nothing was posted." : "\(posted) of \(text.count) characters were posted."
    let apps = runningTargets()
    guard apps.count == 1, let app = apps.first else {
        fail("\(notFront) \(apps.isEmpty ? "does not run" : "is the ID of \(apps.count) running apps"). \(done)", 4)
    }
    func isFront() -> Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier }
    if isFront() { return app }
    app.activate(options: [])
    for _ in 0..<100 {
        wait20ms()
        if isFront() { return app }
    }
    fail("\(notFront) did not come to the front in 2 s. \(done)", 4)
}

// The key events: each modifier key down, the key down and up, each modifier key up.
let modifiers: [(flag: String, code: CGKeyCode, mask: CGEventFlags)] = [
    ("--command", 55, .maskCommand), ("--shift", 56, .maskShift), ("--option", 58, .maskAlternate),
    ("--control", 59, .maskControl),
]
var keyEvents: [(code: CGKeyCode, down: Bool, mask: CGEventFlags)] = []
let held = modifiers.filter { flags.contains($0.flag) }
/// The flags of the key or the wheel events: every held modifier.
let heldMask = held.reduce(into: CGEventFlags()) { $0.insert($1.mask) }
func modifierKeys(down: Bool) -> [(code: CGKeyCode, down: Bool, mask: CGEventFlags)] {
    var mask: CGEventFlags = down ? [] : heldMask
    return (down ? held : held.reversed()).map { modifier in
        if down { mask.insert(modifier.mask) } else { mask.remove(modifier.mask) }
        return (modifier.code, down, mask)
    }
}
func printKeys(_ events: [(code: CGKeyCode, down: Bool, mask: CGEventFlags)]) {
    for event in events { print("\(event.down ? "down" : "up") \(event.code) flags \(event.mask.rawValue)") }
}
if command == "key" {
    keyEvents =
        modifierKeys(down: true) + [(CGKeyCode(values[0]), true, heldMask), (CGKeyCode(values[0]), false, heldMask)]
        + modifierKeys(down: false)
    if flags.contains("--dry-run") {
        printKeys(keyEvents)
        exit(0)
    }
}
if command == "type", flags.contains("--dry-run") {
    print("type \(text)")
    exit(0)
}
/// A mouse wheel gives lines; a trackpad gesture gives pixels.
let units: CGScrollEventUnit = flags.contains("--phases") ? .pixel : .line
if command == "scroll", flags.contains("--dry-run") {
    printKeys(modifierKeys(down: true))
    print("wheel \(Int(values[2])) \(Int(values[3])) \(units == .line ? "lines" : "pixels") flags \(heldMask.rawValue)")
    printKeys(modifierKeys(down: false))
    exit(0)
}

// The check comes before the Accessibility check, so a test with no target app posts nothing. A
// bare up and a drag dry run need no target.
let dryDrag = command == "drag" && flags.contains("--dry-run")
let apps = command == "up" && !values.isEmpty ? runningTargets() : []
let target: NSRunningApplication? =
    command == "up" ? (apps.count == 1 ? apps.first : nil) : dryDrag ? nil : requireFront()

/// A window on screen: its owner name, its layer, its bounds in screen points, and whether the
/// target app owns it (by its PID: the real app and the verify copy have the same name).
struct Window {
    let owner: String
    let layer: Int
    let bounds: CGRect
    let target: Bool
}

/// The windows on screen, front to back. A drag dry run reads HID_TEST_WINDOWS (layer 0): the
/// owner `target` is the target app, and the other owners are names, such as Finder.
func screenWindows() -> [Window] {
    if dryDrag {
        let parts = (ProcessInfo.processInfo.environment["HID_TEST_WINDOWS"] ?? "").split(separator: " ")
        guard parts.count % 5 == 0 else { fail("HID_TEST_WINDOWS needs owner x y w h groups.", 2) }
        return stride(from: 0, to: parts.count, by: 5).map { start in
            let numbers = parts[(start + 1)..<(start + 5)].compactMap { Double($0) }
            guard numbers.count == 4 else { fail("HID_TEST_WINDOWS needs owner x y w h groups.", 2) }
            let owner = String(parts[start])
            return Window(
                owner: owner, layer: 0,
                bounds: CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]),
                target: owner == "target")
        }
    }
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.compactMap { window in
        guard let bounds = window[kCGWindowBounds as String] as? [String: Double], let left = bounds["X"],
            let top = bounds["Y"], let width = bounds["Width"], let height = bounds["Height"]
        else { return nil }
        return Window(
            owner: window[kCGWindowOwnerName as String] as? String ?? "",
            layer: window[kCGWindowLayer as String] as? Int ?? -1,
            bounds: CGRect(x: left, y: top, width: width, height: height),
            target: target.map { window[kCGWindowOwnerPID as String] as? pid_t == $0.processIdentifier } ?? false)
    }
}

/// The screen point: the top-left corner of the target window plus the point. A bare up, or an up
/// with no target window, takes the pointer location.
func screenPoint() -> (point: CGPoint, source: String) {
    let pointer = (CGEvent(source: nil)?.location ?? .zero, "pointer")
    if command == "up", values.isEmpty { return pointer }
    // The window of the target app. A layer-0 window (a normal window) comes before a tooltip,
    // which is at a higher layer, as in screenshot.sh.
    let windows = screenWindows()
    let owned = windows.filter(\.target)
    guard let bounds = (owned.first { $0.layer == 0 } ?? owned.first { $0.layer > 0 })?.bounds else {
        if command == "up" { return pointer }
        fail("No Dirigible window on screen. Run make run first.", 1)
    }
    let point = CGPoint(x: bounds.minX + values[0], y: bounds.minY + values[1])
    if command == "drag", flags.contains("--outside") {
        // A drag from the Finder: the mouse-down goes to the frontmost window at the start, which
        // must be a Finder window, and the drop goes to the target window. A window above layer 0
        // (the Dock, a panel) is in front of a normal window.
        let end = CGPoint(x: point.x + values[2], y: point.y + values[3])
        if !bounds.contains(end) {
            fail("The end point \(end.x), \(end.y) is outside the target window (\(bounds)).", 5)
        }
        let front = windows.first { $0.layer >= 0 && $0.bounds.contains(point) }
        if front?.owner != "Finder" {
            let owner = front?.owner ?? "no window"
            fail("The start point \(point.x), \(point.y) is not in a Finder window in front (\(owner)).", 5)
        }
    } else if command != "up", !(0..<bounds.width).contains(values[0]) || !(0..<bounds.height).contains(values[1]) {
        let size = "\(bounds.width) x \(bounds.height)"
        fail("The point \(values[0]), \(values[1]) is outside the target window (\(size)).", 5)
    }
    return (point, "window")
}
if command == "up", flags.contains("--dry-run") {
    let (point, source) = screenPoint()
    print("up \(source) \(Int(point.x)) \(Int(point.y))")
    exit(0)
}
if dryDrag {
    let start = screenPoint().point
    print("drag \(Int(start.x)) \(Int(start.y)) to \(Int(start.x + values[2])) \(Int(start.y + values[3]))")
    exit(0)
}

guard AXIsProcessTrusted() else {
    fail("No Accessibility trust. Add the terminal app in System Settings > Privacy & Security > Accessibility.", 3)
}

func post(_ keys: [(code: CGKeyCode, down: Bool, mask: CGEventFlags)]) {
    for key in keys {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: key.code, keyDown: key.down)
        event?.flags = key.mask
        event?.post(tap: .cghidEventTap)
        wait20ms()
    }
}

switch command {
case "key":
    requireFront()
    post(keyEvents)
    exit(0)
case "type":
    for (posted, character) in text.enumerated() {
        requireFront(posted: posted)
        let utf16 = Array(String(character).utf16)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
            event?.flags = []
            event?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            event?.post(tap: .cghidEventTap)
            wait20ms()
        }
    }
    exit(0)
default:
    break
}

let origin = screenPoint().point

/// A mouse event with the flags of the held modifier keys (an Option drag, run 12).
func mouse(_ type: CGEventType, _ point: CGPoint) {
    let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
    event?.flags = heldMask
    event?.post(tap: .cghidEventTap)
    wait20ms()
}

if command != "up" { requireFront() }
switch command {
case "drag":
    post(modifierKeys(down: true))
    defer { post(modifierKeys(down: false)) }
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
case "move":
    mouse(.mouseMoved, origin)
case "click":
    mouse(.mouseMoved, origin)
    post(modifierKeys(down: true))
    defer { post(modifierKeys(down: false)) }
    let right = flags.contains("--right")
    for clicks in flags.contains("--double") ? [1, 2] : [1] {
        for type: CGEventType in right ? [.rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp] {
            let event = CGEvent(
                mouseEventSource: nil, mouseType: type, mouseCursorPosition: origin, mouseButton: right ? .right : .left
            )
            event?.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
            event?.flags = heldMask
            event?.post(tap: .cghidEventTap)
            wait20ms()
        }
    }
default:  // scroll, with the modifier keys down around the wheel events
    mouse(.mouseMoved, origin)
    post(modifierKeys(down: true))
    defer { post(modifierKeys(down: false)) }
    func wheel(_ dx: Double, _ dy: Double, phase: Int64, momentum: Int64) {
        let event = CGEvent(
            scrollWheelEvent2Source: nil, units: units, wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx),
            wheel3: 0)
        event?.flags = heldMask
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
