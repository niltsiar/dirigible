import Foundation
import Testing

/// The CLI parity rule (AGENTS.md, decisions 0011 and 0041): each public mutating method in
/// DirigibleCore has a `dirigible` command, or an exemption with its reason, and each command has
/// an MCP tool, or a tool exemption with its reason.
struct ParityTests {
    static let commands: [String: [String]] = [
        "addCapture": ["capture add"],
        "removeCapture": ["capture remove"],
        "addFile": ["file add"],
        "removeFile": ["file remove"],
        "addTrack": ["track add"],
        "addCallTracks": ["track add-call"],
        "removeTrack": ["track remove"],
        "renameTrack": ["track rename"],
        "setGain": ["track gain", "clip gain"],
        "setRoute": ["track route"],
        "setLayout": ["track layout"],
        "setMuted": ["track mute"],
        "setSoloed": ["track solo"],
        "setMarker": ["marker set"],
        "removeMarker": ["marker remove"],
        "place": ["clip place"],
        "clear": ["clip clear"],
        "split": ["clip split"],
        "move": ["clip move"],
        "trim": ["clip trim"],
        "paste": ["clip paste", "clip paste-clips"],
        "splitClips": ["clip split-at"],
        "nudge": ["clip nudge"],
        "removeClips": ["clip remove"],
        "setFades": ["clip fade"],
        "setGains": ["clip gain"],
        "setCrossfades": ["clip crossfade"],
        "rippleDelete": ["clip ripple-delete"],
        "rippleInsert": ["clip ripple-insert"],
        "rippleTrim": ["clip ripple-trim"],
    ]

    static let exemptions: [String: String] = [
        "setRecording": "Only the capture run writes <recording> (decision 0004).",
        "edit": "History lives in one process. Each command is one read-edit-save step.",
        "undo": "History lives in one process. Each command is one read-edit-save step.",
        "redo": "History lives in one process. Each command is one read-edit-save step.",
    ]

    /// The commands with no MCP tool (decision 0041).
    static let toolExemptions: [String: String] = [
        "capture add": "It writes raw clock data that only a capture run measures.",
        "file add": "It adds a file record and does not read the audio. An agent that needs it runs the CLI.",
    ]

    /// The tools that are not an edit command.
    static let readTools: Set<String> = ["session_create", "session_info"]

    @Test func everyMutatingSessionMethodHasACommandOrAnExemption() throws {
        let names = try publicMutatingMethods()
        #expect(names.count >= 18, "The scan found only \(names.sorted())")
        for name in names.sorted() where Self.commands[name] == nil && Self.exemptions[name] == nil {
            Issue.record("\(name) has no dirigible command and no exemption in ParityTests")
        }
        let stale = Set(Self.commands.keys).union(Self.exemptions.keys).subtracting(names)
        #expect(stale.isEmpty, "ParityTests lists methods that do not exist: \(stale.sorted())")
    }

    @Test func everyListedCommandExists() async throws {
        for command in Self.commands.values.joined().sorted() {
            let result = try await dirigible(command.split(separator: " ").map(String.init) + ["--help"])
            // --help exits 0 for any words, so the usage line proves that the command exists.
            #expect(
                result.stdout.contains("USAGE: dirigible \(command) <package>"), "dirigible \(command) does not exist")
        }
    }

    /// The tool name is the command words with `_` for each space and hyphen.
    @Test func everyListedCommandHasATool() async throws {
        let answers = try await mcp([modernRequest(1, "tools/list")])
        let names = Set(
            (result(answer(answers, id: 1))["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String })
        let commands = Set(Self.commands.values.joined())
        for command in commands.sorted() where Self.toolExemptions[command] == nil {
            let tool = command.replacing(" ", with: "_").replacing("-", with: "_")
            #expect(names.contains(tool), "dirigible \(command) has no MCP tool \(tool) and no tool exemption")
        }
        let mapped = Set(commands.map { $0.replacing(" ", with: "_").replacing("-", with: "_") })
        #expect(names.subtracting(mapped).subtracting(Self.readTools).isEmpty, "tools with no command")
        #expect(Set(Self.toolExemptions.keys).isSubset(of: commands), "a tool exemption names no command")
        #expect(Self.toolExemptions.values.allSatisfy { !$0.isEmpty })
    }

    private func publicMutatingMethods() throws -> Set<String> {
        let core = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../../Sources/DirigibleCore").standardized
        let files = try FileManager.default.contentsOfDirectory(at: core, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        var names: Set<String> = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in text.matches(of: /public\s+mutating\s+func\s+(\w+)/) { names.insert(String(match.1)) }
        }
        return names
    }
}
