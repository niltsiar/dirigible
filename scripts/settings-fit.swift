// Check that the Settings window of a running Dirigible shows each text whole: each static text is
// inside the window with a 16 pt margin at the sides and the bottom, and the window is at most
// 720 x 400 pt. No unit test can see a clip: the test process has no app strings, and an offscreen
// render draws no SwiftUI text. screenshots.sh runs this check in English. For Spanish, start the
// verify copy with `--args -AppleLanguages "(es)"`, open Settings, and run this script.
// The terminal app needs the Accessibility permission (as for ax.swift).
//
// usage: settings-fit.swift <pid>   one line per text (FIT or CLIP) and the window size; exit 1
//                                   when a text is clipped or the window is too large, exit 2
//                                   when no Settings window shows
import AppKit
import ApplicationServices

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func frame(_ element: AXUIElement) -> CGRect {
    var origin = CGPoint.zero
    var size = CGSize.zero
    if let value = attribute(element, kAXPositionAttribute) { AXValueGetValue(value as! AXValue, .cgPoint, &origin) }
    if let value = attribute(element, kAXSizeAttribute) { AXValueGetValue(value as! AXValue, .cgSize, &size) }
    return CGRect(origin: origin, size: size)
}

func elements(_ element: AXUIElement) -> [AXUIElement] {
    [element] + ((attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []).flatMap(elements)
}

guard CommandLine.arguments.count == 2, let pid = pid_t(CommandLine.arguments[1]) else {
    print("usage: settings-fit.swift <pid>")
    exit(2)
}
let windows = (attribute(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AXUIElement]) ?? []
// The Settings window is the window with the agent switch.
guard
    let settings = windows.first(where: { window in
        elements(window).contains { attribute($0, kAXSubroleAttribute) as? String == "AXSwitch" }
    })
else {
    print("settings-fit.swift: no Settings window")
    exit(2)
}
let bounds = frame(settings)
let inside = bounds.insetBy(dx: 16, dy: 0)
var clipped = 0
for element in elements(settings) where attribute(element, kAXRoleAttribute) as? String == "AXStaticText" {
    let box = frame(element)
    let fits = box.minX >= inside.minX && box.maxX <= inside.maxX && box.maxY <= bounds.maxY - 16
    if !fits { clipped += 1 }
    print("\(fits ? "FIT " : "CLIP") \(box) \(attribute(element, kAXValueAttribute) as? String ?? "")")
}
let small = bounds.width <= 720 && bounds.height <= 400
print("\(small ? "SIZE" : "TOO LARGE") \(bounds.size)")
exit(clipped == 0 && small ? 0 : 1)
