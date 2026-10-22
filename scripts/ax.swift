// Read and act on the accessibility tree of the running Dirigible app, for app checks in the
// verify phase: the path of VoiceOver, from outside the process. Start the app first with
// `make run`, or set `DIRIGIBLE_BUNDLE_ID` (`scripts/verify-copy.sh ax` sets it for the verify
// copy). With no variable, the bundle ID is com.delineas.dirigible. The terminal app needs the
// Accessibility permission (as for hid.swift).
// A call of an accessibility method in a test does not prove that the tree reaches the element
// (run 1b: the header ruler was a leaf, so the handle and the track rows were not in the tree).
//
// usage: ax.swift dump [<depth>] [--tree <file>] [--witness <text>]
//                                             one line per element: role, title, label, value, help;
//                                             with --tree, the lines of a dump file; with
//                                             --witness, exit 1 when no line of the dump has <text>
//                                             (a text of only the state to read, for example a
//                                             progress Value=0.): that dump is void, so read again
//                                             in the state
//        ax.swift find <text>                 the elements whose line has <text>
//        ax.swift press <path> [--tree <file>] [--role <role>]
//                                             the press action of the one element that <path>
//                                             selects; with --tree, the match in a dump file,
//                                             and no press; with --role, only the elements with
//                                             the role, for example AXMenuBarItem to open a menu
//        ax.swift step <role> <increment|decrement>
//                                             the action on each element with the role, for
//                                             example AXSplitter, with its line before and after
// A menu item line also shows its key: MenuItemCmdChar, MenuItemCmdModifiers (0 Command, 1 Shift,
// 2 Option, 4 Control, 8 no Command; add the values), and MenuItemCmdVirtualKey (for a key with no
// character, for example 36 Return or 123 Left Arrow). A menu title can end in the "…" character:
// copy the title from the dump for press. A menu item with a check mark shows MenuItemMarkChar=✓.
// Each line ends in Enabled= (1 or 0) when the element has the attribute; a closed menu shows
// the current state too. To open a menu, press its title with --role AXMenuBarItem: in English,
// the Record menu has a Record item, so "press Record" alone matches both and is refused.
// A press path is titles with " > " between them, for example "File > Open Recent > Clear Menu".
// The last title is the title of the element. The other titles come in this order among the
// titles above it. When two elements match, press refuses and lists their paths: give a longer
// path. The Apple menu is out of the search unless the path starts with "Apple". A press of the
// first "Clear Menu" pressed Apple > Recent Items > Clear Menu and cleared the Recent Items list of
// the Mac (run 2026-09-30-start-window).
// A press path with an empty title is refused: a menu separator has an empty title.
// An element with no title (for example an icon button) has its Description as its title.
// With no match, press lists the path of each element whose title holds the last title.
// Exit: 0 done, 1 no app with the bundle ID, no element, or no witness line, 2 usage, an empty
// title in the press path, or an empty DIRIGIBLE_BUNDLE_ID, 3 no Accessibility trust, 4 more than
// one element matches the press path.
import AppKit
import ApplicationServices

let usage = """
    usage: ax.swift dump [<depth>] [--tree <file>] [--witness <text>]
           ax.swift find <text>
           ax.swift press <path> [--tree <file>] [--role <role>]
           ax.swift step <role> <increment|decrement>

    """

func fail(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

var arguments = Array(CommandLine.arguments.dropFirst())
/// The value of an option of the commands, removed from the arguments.
func option(_ name: String, _ commands: Set<String>) -> String? {
    guard let first = arguments.first, commands.contains(first), let at = arguments.firstIndex(of: name) else {
        return nil
    }
    guard at + 1 < arguments.count else { fail(usage, 2) }
    defer { arguments.removeSubrange(at...at + 1) }
    return arguments[at + 1]
}
let treeFile = option("--tree", ["press", "dump"])
let roleFilter = option("--role", ["press"])
let witness = option("--witness", ["dump"])
let counts = ["dump": 0...1, "find": 1...1, "press": 1...1, "step": 2...2]
guard let command = arguments.first, let count = counts[command], count.contains(arguments.count - 1) else {
    fail(usage, 2)
}
let depth = command == "dump" && arguments.count == 2 ? Int(arguments[1]) : 99
guard let depth else { fail(usage, 2) }
if command == "step", !["increment", "decrement"].contains(arguments[2]) { fail(usage, 2) }
let path = command == "press" ? arguments[1].components(separatedBy: " > ") : []
if path.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
    fail("The press path \"\(arguments[1])\" has an empty title. Give one title between each \" > \".", 2)
}
let bundleID = ProcessInfo.processInfo.environment["DIRIGIBLE_BUNDLE_ID"] ?? "com.delineas.dirigible"
if bundleID.isEmpty { fail("DIRIGIBLE_BUNDLE_ID is empty. Unset it, or give a bundle ID.", 2) }

func appRoot() -> AXUIElement {
    guard AXIsProcessTrusted() else {
        fail("No Accessibility trust. Add the terminal app in System Settings > Privacy & Security > Accessibility.", 3)
    }
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    else { fail("No app with the bundle ID \(bundleID) runs. Run make run, or scripts/verify-copy.sh start.", 1) }
    return AXUIElementCreateApplication(app.processIdentifier)
}

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
    [
        "AXRole", "AXRoleDescription", "AXTitle", "AXDescription", "AXValue", "AXHelp",
        "AXMenuItemCmdChar", "AXMenuItemCmdModifiers", "AXMenuItemCmdVirtualKey", "AXMenuItemMarkChar",
        "AXEnabled",
    ].compactMap { name in
        attribute(element, name).map { value in
            // The key of Return is "\r", so the key prints in quotes and does not split the line.
            let text = name == "AXMenuItemCmdChar" ? String(describing: value).debugDescription : "\(value)"
            return "\(name.dropFirst(2))=\(text)"
        }
    }.joined(separator: " ")
}

/// One element for press: its dump line, role, title, and children. The title is the AXTitle, or
/// the AXDescription when the element has no AXTitle. A tree from a dump file has no element to
/// press.
struct Node {
    let line: String
    let role: String?
    let title: String?
    let element: AXUIElement?
    let children: [Node]
}

func node(_ element: AXUIElement, _ level: Int) -> Node {
    let children = level < depth ? (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] : []
    return Node(
        line: line(element), role: attribute(element, "AXRole") as? String,
        title: (attribute(element, "AXTitle") ?? attribute(element, "AXDescription")) as? String,
        element: element,
        children: children.map { node($0, level + 1) })
}

/// The tree of a `dump` output: one space of indent for each level.
func tree(fromDump text: String) -> Node? {
    let entries = text.split(separator: "\n").map { ($0.prefix { $0 == " " }.count, String($0.drop { $0 == " " })) }
    // A value runs to the next " <Key>=" or to the end of the line.
    let role = try! Regex("(?:^| )Role=(.*?)(?= [A-Za-z]+=|$)")
    let title = try! Regex("(?:^| )Title=(.*?)(?= [A-Za-z]+=|$)")
    let description = try! Regex("(?:^| )Description=(.*?)(?= [A-Za-z]+=|$)")
    func field(_ regex: Regex<AnyRegexOutput>, _ text: String) -> String? {
        guard let match = text.firstMatch(of: regex) else { return nil }
        return match.output[1].substring.map(String.init)
    }
    var index = 0
    func parse(_ level: Int) -> [Node] {
        var nodes: [Node] = []
        while index < entries.count, entries[index].0 == level {
            let text = entries[index].1
            index += 1
            nodes.append(
                Node(
                    line: text, role: field(role, text), title: field(title, text) ?? field(description, text),
                    element: nil,
                    children: parse(level + 1)))
        }
        return nodes
    }
    return parse(0).first
}

/// Each element with the last title of the path whose other titles come in order among the titles
/// above it, with its own path of titles.
func matches(_ path: [String], _ node: Node, _ above: [String]) -> [(node: Node, titles: [String])] {
    if node.role == "AXMenuBarItem", node.title == "Apple", path.first != "Apple" { return [] }
    var rest = path.dropLast()[...]
    for title in above where title == rest.first { rest.removeFirst() }
    let titles = above + [node.title].compactMap { $0 }.filter { !$0.isEmpty }
    let own = node.title == path.last && rest.isEmpty ? [(node: node, titles: titles)] : []
    return own + node.children.flatMap { matches(path, $0, titles) }
}

/// The path of each element whose title holds the last title of the path in any case, for the
/// message of a press with no match. The Apple menu stays out, as in `matches`.
func holders(_ path: [String], _ node: Node, _ above: [String]) -> [String] {
    if node.role == "AXMenuBarItem", node.title == "Apple", path.first != "Apple" { return [] }
    let titles = above + [node.title].compactMap { $0 }.filter { !$0.isEmpty }
    let own = node.title?.localizedCaseInsensitiveContains(path.last ?? "") == true ? [titles.joined(separator: " > ")] : []
    return own + node.children.flatMap { holders(path, $0, titles) }
}

var found = false
switch command {
case "dump":
    var lines: [String] = []
    if let treeFile {
        guard let text = try? String(contentsOfFile: treeFile, encoding: .utf8) else {
            fail("No tree in \(treeFile).", 1)
        }
        lines = text.split(separator: "\n").map(String.init).filter { $0.prefix { $0 == " " }.count <= depth }
    } else {
        walk(appRoot(), 0) { element, level in lines.append(String(repeating: " ", count: level) + line(element)) }
    }
    lines.forEach { print($0) }
    if let witness, !lines.contains(where: { $0.contains(witness) }) { fail("no witness: \(witness)", 1) }
    found = true
case "find":
    walk(appRoot(), 0) { element, _ in
        let text = line(element)
        if text.contains(arguments[1]) {
            print(text)
            found = true
        }
    }
case "press":
    let top: Node
    if let treeFile {
        guard let text = try? String(contentsOfFile: treeFile, encoding: .utf8), let parsed = tree(fromDump: text)
        else { fail("No tree in \(treeFile).", 1) }
        top = parsed
    } else {
        top = node(appRoot(), 0)
    }
    let all = matches(path, top, []).filter { roleFilter == nil || $0.node.role == roleFilter }
    if all.count > 1 {
        let list = all.map { "  " + $0.titles.joined(separator: " > ") }.joined(separator: "\n")
        fail("\(all.count) elements match \"\(arguments[1])\". Give a longer path:\n\(list)", 4)
    }
    guard let match = all.first else {
        let paths = holders(path, top, []).map { "  " + $0 }.joined(separator: "\n")
        fail("No element matches \"\(arguments[1])\"." + (paths.isEmpty ? "" : " Paths that hold the title:\n\(paths)"), 1)
    }
    let title = match.titles.joined(separator: " > ")
    if let element = match.node.element {
        AXUIElementPerformAction(element, kAXPressAction as CFString)
        print("pressed: \(title): \(match.node.line)")
    } else {
        print("match: \(title)")
    }
    found = true
default:  // step
    let action = arguments[2] == "increment" ? kAXIncrementAction : kAXDecrementAction
    walk(appRoot(), 0) { element, _ in
        guard attribute(element, "AXRole") as? String == arguments[1] else { return }
        print("before: \(line(element))")
        AXUIElementPerformAction(element, action as CFString)
        usleep(300_000)
        print("after: \(line(element))")
        found = true
    }
}
exit(found ? 0 : 1)
