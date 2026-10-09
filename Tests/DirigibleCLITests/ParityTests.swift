import ArgumentParser
import Foundation
import Testing

@testable import DirigibleCLI

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
        "capture place": "Long audio work that needs progress and cancel (Release 3).",
        "take finalize": "Long audio work that needs progress and cancel (Release 3).",
        "import": "Long audio work that needs progress and cancel (Release 3).",
        "level": "Long audio work that needs progress and cancel (Release 3).",
        "loudness": "Long audio work that needs progress and cancel (Release 3).",
        "peaks": "Long audio work that needs progress and cancel (Release 3).",
        "render": "Long audio work that needs progress and cancel (Release 3).",
        "export": "Long audio work that needs progress and cancel (Release 3).",
        "chapters export": "It writes a file outside the package and edits nothing; session_info gives the markers.",
        "record": "Recording needs the consent sheet of the app (Release 3).",
        "devices": "It lists the audio devices of this Mac, not a package.",
        "apps": "It lists the apps of this Mac, not a package.",
        "mcp": "It is the MCP server.",
    ]

    /// The commands whose tool name does not follow the name rule.
    static let toolNames = ["create": "session_create", "info": "session_info"]

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

    /// Each leaf command of the CLI command tree has its tool, or a tool exemption with its
    /// reason. The tool name is the command words with `_` for each space and hyphen, or the name
    /// in `toolNames`. Each tool maps back to a command.
    @Test func everyCommandHasATool() async throws {
        let answers = try await mcp([modernRequest(1, "tools/list")])
        let names = Set(
            (result(answer(answers, id: 1))["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String })
        let commands = leafCommands(of: Dirigible.self)
        #expect(commands.count >= 40 && commands.contains("clip ripple-trim"), "the tree scan found \(commands)")
        var mapped: Set<String> = []
        for command in commands.sorted() where Self.toolExemptions[command] == nil {
            let tool = Self.toolNames[command] ?? command.replacing(" ", with: "_").replacing("-", with: "_")
            mapped.insert(tool)
            let found = names.contains(tool)
            #expect(found, "dirigible \(command) has no MCP tool \(tool) and no tool exemption")
        }
        #expect(names.subtracting(mapped).isEmpty, "tools with no command: \(names.subtracting(mapped).sorted())")
        #expect(Set(Self.toolExemptions.keys).isSubset(of: commands), "a tool exemption names no command")
        #expect(Self.toolExemptions.values.allSatisfy { !$0.isEmpty })
    }

    /// The MCP section of the guide names each command with no tool, so a user knows the gap.
    @Test func theGuideNamesEachCommandWithNoTool() throws {
        let guide = try String(
            contentsOf: URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../docs/guide.md"),
            encoding: .utf8)
        let section = guide.components(separatedBy: "### Connect an agent with MCP").dropFirst().first ?? ""
        let text = section.components(separatedBy: "\n### ").first ?? ""
        #expect(!text.isEmpty, "the guide has no MCP section")
        for command in Self.toolExemptions.keys.sorted() where !text.contains("`\(command)`") {
            Issue.record("the MCP section of docs/guide.md does not name \(command), a command with no tool")
        }
    }

    /// The command words of each command that has no subcommand.
    private func leafCommands(of command: any ParsableCommand.Type, _ words: [String] = []) -> Set<String> {
        let subcommands = command.configuration.subcommands
        guard !subcommands.isEmpty else { return [words.joined(separator: " ")] }
        return Set(subcommands.flatMap { leafCommands(of: $0, words + [$0._commandName]) })
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
