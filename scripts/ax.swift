// Read and act on the accessibility tree of the running Dirigible app, for app checks in the
// verify phase: the path of VoiceOver, from outside the process. Start the app first with
// `make run`. The terminal app needs the Accessibility permission (as for hid.swift).
// A call of an accessibility method in a test does not prove that the tree reaches the element
// (run 1b: the header ruler was a leaf, so the handle and the track rows were not in the tree).
//
// usage: ax.swift dump [<depth>]              one line per element: role, title, label, value, help
//        ax.swift find <text>                 the elements whose line has <text>
//        ax.swift press <title>               the press action of the first element with <title>
//        ax.swift step <role> <increment|decrement>
//                                             the action on each element with the role, for
//                                             example AXSplitter, with its line before and after
// Exit: 0 done, 1 no Dirigible app or no element, 2 usage, 3 no Accessibility trust.
import AppKit
import ApplicationServices

let usage = """
    usage: ax.swift dump [<depth>]
           ax.swift find <text>
           ax.swift press <title>
           ax.swift step <role> <increment|decrement>

    """

func fail(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let arguments = Array(CommandLine.arguments.dropFirst())
let counts = ["dump": 0...1, "find": 1...1, "press": 1...1, "step": 2...2]
guard let command = arguments.first, let count = counts[command], count.contains(arguments.count - 1) else {
    fail(usage, 2)
}
let depth = command == "dump" && arguments.count == 2 ? Int(arguments[1]) : 99
guard let depth else { fail(usage, 2) }
if command == "step", !["increment", "decrement"].contains(arguments[2]) { fail(usage, 2) }

guard AXIsProcessTrusted() else {
    fail("No Accessibility trust. Add the terminal app in System Settings > Privacy & Security > Accessibility.", 3)
}
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.delineas.dirigible").first
else { fail("No Dirigible app runs. Run make run first.", 1) }
let root = AXUIElementCreateApplication(app.processIdentifier)

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    AXUIElementCopyAttributeValue(element, name as CFString, &value)
    return value
}

func walk(_ element: AXUIElement, _ level: Int, _ visit: (AXUIElement, Int) -> Void) {
    visit(element, level)
    guard level < depth else { return }
    for child in (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(child, level + 1, visit) }
}

func line(_ element: AXUIElement) -> String {
    ["AXRole", "AXRoleDescription", "AXTitle", "AXDescription", "AXValue", "AXHelp"].compactMap { name in
        attribute(element, name).map { "\(name.dropFirst(2))=\($0)" }
    }.joined(separator: " ")
}

var found = false
switch command {
case "dump":
    walk(root, 0) { element, level in print(String(repeating: " ", count: level) + line(element)) }
    found = true
case "find":
    walk(root, 0) { element, _ in
        let text = line(element)
        if text.contains(arguments[1]) {
            print(text)
            found = true
        }
    }
case "press":
    walk(root, 0) { element, _ in
        guard !found, attribute(element, "AXTitle") as? String == arguments[1] else { return }
        AXUIElementPerformAction(element, kAXPressAction as CFString)
        print("pressed: \(line(element))")
        found = true
    }
default:  // step
    let action = arguments[2] == "increment" ? kAXIncrementAction : kAXDecrementAction
    walk(root, 0) { element, _ in
        guard attribute(element, "AXRole") as? String == arguments[1] else { return }
        print("before: \(line(element))")
        AXUIElementPerformAction(element, action as CFString)
        usleep(300_000)
        print("after: \(line(element))")
        found = true
    }
}
exit(found ? 0 : 1)
