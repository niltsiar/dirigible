import ArgumentParser
import Foundation
import Testing

@testable import DirigibleCLI
@testable import DirigibleMCP

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
        "setRole": ["track role"],
        "setMarker": ["marker set"],
        "removeMarker": ["marker remove"],
        "setEpisode": ["episode set"],
        "set": ["episode set"],
        "place": ["clip place"],
        "clear": ["clip clear"],
        "split": ["clip split"],
        "move": ["clip move"],
        "trim": ["clip trim"],
        "paste": ["clip paste", "clip paste-clips"],
        "replace": ["clip replace"],
        "fill": ["clip fill"],
        "splitClips": ["clip split-at"],
        "splitStereo": ["clip split-stereo"],
        "nudge": ["clip nudge"],
        "removeClips": ["clip remove"],
        "setFades": ["clip fade"],
        "setGains": ["clip gain"],
        "setEnvelope": ["clip envelope"],
        "changeGain": ["clip gain-range"],
        "setCrossfades": ["clip crossfade"],
        "rippleDelete": ["clip ripple-delete"],
        "rippleInsert": ["clip ripple-insert"],
        "rippleTrim": ["clip ripple-trim"],
        "removeUnusedFiles": ["file prune"],
        "importTranscript": ["transcript import"],
        "addTranscript": ["transcribe"],
        "cutWords": ["transcript cut"],
        "editSilences": ["silence-edit"],
        "importChapters": ["chapters import"],
        "heal": ["clip heal"],
        "restoreOriginals": ["clip restore"],
        "repoint": ["clip denoise", "clip repair"],
        "duck": ["duck"],
        "closeGaps": ["clip close-gaps"],
        "roll": ["clip roll"],
        "slip": ["clip slip"],
        "setFollowTrack": ["track follow"],
        "setExportPreset": ["preset set"],
        "removeExportPreset": ["preset remove"],
        "addBin": ["bin add"],
        "renameBin": ["bin rename"],
        "moveBin": ["bin move"],
        "removeBin": ["bin remove"],
        "addItem": ["bin item-add"],
        "renameItem": ["bin item-rename"],
        "removeItem": ["bin item-remove"],
        "setMatch": ["track match-voice"],
        "setMatchAmount": ["track match-voice"],
        "setMatchBypassed": ["track match-voice"],
        "removeMatch": ["track match-voice"],
        "shuffle": ["clip shuffle"],
        "sync": ["clip sync"],
        "correctDrift": ["clip sync"],
    ]

    static let exemptions: [String: String] = [
        "setRecording": "Only the capture run writes <recording> (decision 0004).",
        "edit": "History lives in one process. Each command is one read-edit-save step.",
        "undo": "History lives in one process. Each command is one read-edit-save step.",
        "redo": "History lives in one process. Each command is one read-edit-save step.",
        "amend": "History lives in one process, so a CLI process has no earlier edit to join.",
    ]

    /// The commands with no MCP tool (decision 0041).
    static let toolExemptions: [String: String] = [
        "capture add": "It writes raw clock data that only a capture run measures.",
        "file add": "It adds a file record and does not read the audio. An agent that needs it runs the CLI.",
        "capture place": "Long audio work that needs progress and cancel (Release 3).",
        "take finalize": "Long audio work that needs progress and cancel (Release 3).",
        "peaks": "Long audio work that needs progress and cancel (Release 3).",
        "mcp": "It is the MCP server.",
        "skill show": "It reads no package: the skill text of the agent manual (decision 0051).",
        "skill path": "It reads no package: the path of the bundled skill file (decision 0051).",
        "diagnostics collect":
            "It reads no package and changes none: a report zip that the user sends (decision 0059).",
        "model check":
            "It reads no package and changes none: the helper of a model file check in the app (decision 0065, D8).",
        "favorites path": "It reads no package and changes none: the path of the Favorites store (decision 0081).",
    ]

    /// The commands whose tool name does not follow the name rule.
    static let toolNames = Dictionary(uniqueKeysWithValues: Tool.commandNames.map { ($0.value, $0.key) })

    @Test func everyMutatingSessionMethodHasACommandOrAnExemption() throws {
        let names = try publicMutatingMethods()
        #expect(names.count >= 18, "The scan found only \(names.sorted())")
        for name in names.sorted() where Self.commands[name] == nil && Self.exemptions[name] == nil {
            Issue.record("\(name) has no dirigible command and no exemption in ParityTests")
        }
        let stale = Set(Self.commands.keys).union(Self.exemptions.keys).subtracting(names)
        #expect(stale.isEmpty, "ParityTests lists methods that do not exist: \(stale.sorted())")
    }

    /// A comment that holds the words gives no name: a comment-only change runs no Swift test
    /// before the push (check-changed.sh).
    @Test func theScanSkipsCommentLines() {
        let text = """
            /// Call `public mutating func ghost()` for a ghost.
              // public mutating func shadow() {}
            public mutating func real() {}
            """
        #expect(publicMutatingNames(in: text) == ["real"])
    }

    @Test func everyListedCommandExists() async throws {
        for command in Self.commands.values.joined().sorted() {
            let result = try await dirigible(command.split(separator: " ").map(String.init) + ["--help"])
            // --help exits 0 for any words, so the usage line proves that the command exists. A
            // command with many options shows them as [<options>] before the package.
            let usage = ["", "[<options>] "].map { "USAGE: dirigible \(command) \($0)<package>" }
            #expect(usage.contains { result.stdout.contains($0) }, "dirigible \(command) does not exist")
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
        let text = try Self.guideSection("Connect an AI agent")
        #expect(!text.isEmpty, "the guide has no MCP section")
        for command in Self.toolExemptions.keys.sorted() where !text.contains("`\(command)`") {
            Issue.record("the MCP section of docs/guide.md does not name \(command), a command with no tool")
        }
    }

    /// The guide line of the commands with no tool names no command that has a tool, so the guide
    /// does not send a user to the terminal for a tool that exists (run 7b, C15).
    @Test func theGuideNamesNoToolAsACommandWithNoTool() throws {
        let guide = try Self.guideText()
        let line = guide.split(separator: "\n").first { $0.hasPrefix("- These commands have no tool.") } ?? ""
        let commands = leafCommands(of: Dirigible.self)
        let named = line.matches(of: /`([^`]+)`/).map { String($0.1) }.filter(commands.contains)
        #expect(named.count >= 5, "the scan found too few commands: \(named)")
        for command in named where Self.toolExemptions[command] == nil {
            Issue.record("docs/guide.md lists \(command) as a command with no tool, but it has a tool")
        }
    }

    /// The guide section for people that names what the agent manual gives (decision 0051, C10).
    @Test func theGuideNamesEachRecipe() throws {
        let section = try Self.guideSection("What you can ask an agent")
        #expect(!section.isEmpty, "the guide has no section What you can ask an agent")
        for recipe in AgentManual.recipes where !section.contains("`\(recipe.name)`") {
            Issue.record("the agent section of docs/guide.md does not name the recipe \(recipe.name)")
        }
        for text in ["`dirigible --instructions`", "`dirigible skill path`", "~/.claude/skills", "~/.agents/skills"] {
            #expect(section.contains(text), "the agent section does not name \(text)")
        }
        let requests = section.split(separator: "\n").filter { $0.hasPrefix("- \"") }
        #expect(requests.count >= 5, "the agent section has \(requests.count) example requests")
        // W10 and W15: a voice request, and a request of the prepare and the edit phases.
        #expect(requests.contains { $0.contains("`track_match_voice`") }, "no voice request")
        #expect(!section.contains("no voice profile"), "the agent section still says that no voice feature exists")
        #expect(requests.contains { $0.contains("Record the host from") }, "no route request")
        #expect(requests.contains { $0.contains("transcript") }, "no transcript request")
    }

    /// Each one-word span of the agent section names a tool, an argument, an enum value, or a
    /// command word. The control: the scan finds a bad name in a guide line.
    @Test func theGuideSpansHaveAClass() throws {
        let section = try Self.guideSection("What you can ask an agent")
        #expect(ManualScan.spans(in: section).count >= 5, "the scan found too few spans")
        #expect(ManualScan.spansWithNoClass(in: section).isEmpty, "\(ManualScan.spansWithNoClass(in: section))")
        #expect(ManualScan.spansWithNoClass(in: "- Ask the agent to run `clip_explode`.") == ["clip_explode"])
    }

    /// The commands that the agent manual does not name (user rule of 2026-10-13: the manual and
    /// the skill stay current, as the guide does).
    static let manualExemptions: [String: String] = [
        "capture add": "It writes raw clock data that only a capture run measures.",
        "file add": "It adds a file record with no audio check; the manual names import, which adds a file and a clip.",
        "capture place": "It recovers a segment of a take; the app and take finalize place each segment.",
        "take finalize": "It recovers a take after a crash; the app does it at launch.",
        "peaks": "It prints the peak cache of the app; an agent reads the levels with loudness.",
        "mcp": "It is the MCP server that sends the manual.",
        "skill show": "It prints the skill itself.",
        "skill path": "The guide names it for the person who links the skill.",
    ]

    /// Each tool and each command is named in the manual, a recipe, or the tool table of the skill,
    /// or has a manual exemption with its reason (code gate 1 item 1).
    @Test func theManualNamesEachToolAndCommand() {
        let commands = leafCommands(of: Dirigible.self)
        let rows = AgentManual.skill.split(separator: "\n").compactMap {
            $0.wholeMatch(of: /\| ([a-z_]+) \| dirigible ([a-z -]+) \|/)
        }
        let table = Dictionary(rows.map { (String($0.1), String($0.2)) }) { first, _ in first }
        #expect(Set(table.keys) == Set(Tool.all.map(\.name)), "the skill table and the tools differ")
        for (tool, command) in table.sorted(by: { $0.key < $1.key }) where !commands.contains(command) {
            Issue.record("the skill table gives \(tool) the command \(command), which does not exist")
        }
        let text = ([AgentManual.manual(pathLine: "x"), AgentManual.skill] + AgentManual.recipes.map(\.steps))
            .joined(separator: "\n")
        let lines = ManualScan.commandLines(in: text).map { $0 + " " }
        for command in commands.sorted() where Self.manualExemptions[command] == nil {
            let named = table.values.contains(command) || lines.contains { $0.hasPrefix("dirigible \(command) ") }
            #expect(named, "the manual does not name dirigible \(command), and it has no manual exemption")
        }
        let stale = Self.manualExemptions.keys.filter { !commands.contains($0) || table.values.contains($0) }
        #expect(stale.isEmpty, "stale manual exemptions: \(stale.sorted())")
        #expect(Self.manualExemptions.values.allSatisfy { !$0.isEmpty })
    }

    static func guideText() throws -> String {
        try String(
            contentsOf: URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../docs/guide.md"),
            encoding: .utf8)
    }

    /// The section of docs/guide.md with this heading text, at any level (see `section(titled:in:)`).
    static func guideSection(_ title: String) throws -> String {
        try section(titled: title, in: guideText())
    }

    /// The leaf commands that the code spans of a guide text do not name, sorted. A span names a
    /// leaf as `dirigible <leaf>` or `swift run dirigible <leaf>`, or starts with `<leaf>` (the
    /// guide writes `bin add` after `dirigible bin list`).
    static func leavesNotNamed(in guide: String, among leaves: Set<String>) -> [String] {
        let spans = guide.matches(of: /`([^`\n]+)`/).map {
            String($0.1.trimmingPrefix("swift run ").trimmingPrefix("dirigible "))
        }
        return leaves.filter { leaf in !spans.contains { $0 == leaf || $0.hasPrefix(leaf + " ") } }.sorted()
    }

    @Test func theLeafScanFindsACommandThatTheTextDoesNotName() {
        let leaves: Set = ["clip trim", "clip split", "peaks"]
        let lacking = "Run `dirigible clip split Demo.dirigible` then `peaks`. The words clip trim are no span."
        #expect(Self.leavesNotNamed(in: lacking, among: leaves) == ["clip trim"])
        let naming = "`swift run dirigible clip split Demo.dirigible`, `clip trim Demo.dirigible`, `dirigible peaks`."
        #expect(Self.leavesNotNamed(in: naming, among: leaves).isEmpty)
        let near = "`clip trim-all Demo.dirigible`, `clip split`, `dirigible peaks`."
        #expect(Self.leavesNotNamed(in: near, among: leaves) == ["clip trim"])
    }

    /// The guide names each leaf command of the CLI tree, so a command that a change adds or
    /// renames cannot leave the guide stale.
    @Test func theGuideNamesEachLeafCommand() throws {
        let commands = leafCommands(of: Dirigible.self)
        #expect(commands.count >= 40 && commands.contains("clip ripple-trim"), "the tree scan found \(commands)")
        for command in Self.leavesNotNamed(in: try Self.guideText(), among: commands) {
            Issue.record("docs/guide.md does not name dirigible \(command)")
        }
    }

    /// The lines after the heading with this text, at any level, up to the next heading of the same
    /// or a higher level. The subsections are in it. A `#` line in a code block is not a heading.
    /// The text is empty when no heading has this text.
    static func section(titled title: String, in markdown: String) -> String {
        var openLevel: Int?
        var lines: [Substring] = []
        var inCodeBlock = false
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("```") { inCodeBlock.toggle() }
            let level = line.prefix(while: { $0 == "#" }).count
            if !inCodeBlock, (1...6).contains(level), line.dropFirst(level).hasPrefix(" ") {
                if let open = openLevel, level <= open { break }
                if openLevel == nil, String(line.dropFirst(level + 1)) == title {
                    openLevel = level
                    continue
                }
            }
            if openLevel != nil { lines.append(line) }
        }
        return lines.joined(separator: "\n")
    }

    /// A guide heading is found by its text when a later edit moves it to another level.
    @Test func aGuideSectionIsFoundByItsHeadingTextAtAnyLevel() {
        let text = [
            "# Top", "## Other", "no", "### Agent", "one", "#### Deeper", "two", "```", "# not a heading", "```",
            "three", "### Next", "four", "",
        ].joined(separator: "\n")
        let h3 = Self.section(titled: "Agent", in: text)
        #expect(h3 == "one\n#### Deeper\ntwo\n```\n# not a heading\n```\nthree")
        let h2 = Self.section(titled: "Agent", in: text.replacing("### Agent", with: "## Agent"))
        #expect(h2.hasPrefix("one\n") && h2.contains("three") && h2.contains("four"))
        #expect(Self.section(titled: "Missing", in: text).isEmpty)
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
            names.formUnion(publicMutatingNames(in: try String(contentsOf: file, encoding: .utf8)))
        }
        return names
    }

    /// The names after `public mutating func` in the lines that are not `//` comments.
    private func publicMutatingNames(in text: String) -> Set<String> {
        let code = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingPrefix(while: \.isWhitespace).hasPrefix("//") }.joined(separator: "\n")
        return Set(code.matches(of: /public\s+mutating\s+func\s+(\w+)/).map { String($0.1) })
    }
}
