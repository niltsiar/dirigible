import DirigibleCore
import Foundation
import Testing

/// The tools `silences`, `nearest_pause`, and `meter` of `dirigible mcp` on the files (decisions
/// 0049 and 0062). The fixture is the package of `ReadCommandTests`.
struct ReadToolTests {
    let fixture: ReadCommandTests

    init() throws { fixture = try ReadCommandTests() }

    var path: String { fixture.package.path }

    @Test func theReadToolsAreListedReadOnly() async throws {
        let answers = try await mcp([modernRequest(1, "tools/list")])
        let tools = result(answer(answers, id: 1))["tools"] as? [[String: Any]] ?? []
        for name in ["silences", "nearest_pause", "meter"] {
            let tool = tools.first { $0["name"] as? String == name }
            #expect((tool?["annotations"] as? [String: Bool])?["readOnlyHint"] == true, "\(name): \(tool ?? [:])")
        }
        let meter = tools.first { $0["name"] as? String == "meter" }?["description"] as? String ?? ""
        #expect(meter.contains("heard stereo mix, as a stereo export"), "\(meter)")
    }

    /// Decision 0062: each text of a silence read gives the 60 s edge limit that its warning line reports.
    @Test func eachSilenceReadTextStatesTheEdgeLimit() async throws {
        let answers = try await mcp([modernRequest(1, "tools/list")])
        let tools = result(answer(answers, id: 1))["tools"] as? [[String: Any]] ?? []
        var texts: [String: String] = [:]
        for name in ["silences", "nearest_pause"] {
            texts["tool \(name)"] = tools.first { $0["name"] as? String == name }?["description"] as? String
            let help = try await dirigible(name.replacingOccurrences(of: "_", with: "-"), "--help")
            texts["help \(name)"] = help.stdout
        }
        #expect(texts.count == 4)
        for (name, text) in texts {
            let words = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            #expect(words.contains("60 s past") && words.contains("stops there"), "\(name): \(words)")
        }
    }

    /// The work refuses a level of 0 dB and over, so the schema gives -96 up to under 0.
    @Test func theLevelArgumentsHaveASchemaUnderZero() async throws {
        let answers = try await mcp([modernRequest(1, "tools/list")])
        let tools = result(answer(answers, id: 1))["tools"] as? [[String: Any]] ?? []
        for (name, key) in [
            ("silences", "threshold"), ("nearest_pause", "threshold"), ("duck", "threshold"), ("duck", "depth"),
        ] {
            let schema = tools.first { $0["name"] as? String == name }?["inputSchema"] as? [String: Any]
            let property = (schema?["properties"] as? [String: Any])?[key] as? [String: Any] ?? [:]
            #expect(
                property["exclusiveMaximum"] as? Double == 0 && property["minimum"] as? Double == -96
                    && property["maximum"] == nil, "\(name) \(key): \(property)")
        }
    }

    /// The tool text is the stderr lines and then the stdout lines of the command; a refusal names
    /// the option as the tool spells it.
    @Test func eachToolGivesTheTextOfItsCommand() async throws {
        try fixture.package.edit { try $0.setMuted(false, tracks: ["t2"]) }
        let calls: [(tool: String, arguments: [String: Any], command: [String])] = [
            (
                "silences", ["track": ["t1"], "min_length": 2400],
                ["silences", "PKG", "--track", "t1", "--min-length", "2400"]
            ),
            (
                "nearest_pause", ["at": 50_000, "track": ["t1"]],
                ["nearest-pause", "PKG", "--at", "50000", "--track", "t1"]
            ),
            ("meter", ["step": 48_000], ["meter", "PKG", "--step", "48000"]),
            ("meter", ["step": 1000], ["meter", "PKG", "--step", "1000"]),
        ]
        let answers = try await mcp(
            calls.enumerated().map {
                toolCall($0.offset + 2, $0.element.tool, ["package": path].merging($0.element.arguments) { $1 })
            })
        for (index, call) in calls.enumerated() {
            let tool = toolResult(answer(answers, id: index + 2))
            let command = try await fixture.package.run(call.command)
            let stderr = command.stderr.split(separator: "\n").map(String.init)
            let text: String
            if command.status == 0 {
                text = (stderr + command.stdout.split(separator: "\n").map(String.init)).joined(separator: "\n")
            } else {
                // A usage error: `Error: <text>` and then the usage lines.
                text = (stderr.first ?? "").replacing("Error: ", with: "").replacing("--step", with: "step")
            }
            #expect(tool.text == text && tool.isError == (command.status != 0), "\(call.tool): \(tool) for \(command)")
        }
    }

    /// Progress values that grow below 100, then a cancel: no answer, and the next call answers.
    @Test func aReadReportsProgressAndStopsOnCancel() async throws {
        // Track `t1` only: the missing file of `t2` refuses `silences` before its scan.
        let read: [String: Any] = ["package": path, "track": ["t1"]]
        let full = try await mcpLines([toolCall(2, "silences", read, token: 1)])
        let values = notifications(full).compactMap { ($0["params"] as? [String: Any])?["progress"] as? Double }
        #expect(values.count >= 2 && values == values.sorted() && values.allSatisfy { $0 < 100 }, "\(values)")
        let cancelled = try await mcpLines([
            toolCall(2, "meter", read, token: 1), cancelLine(2), modernRequest(3, "ping"),
        ])
        #expect(cancelled.contains { $0["id"] as? Int == 3 }, "the ping after the cancel has its answer: \(cancelled)")
        #expect(!cancelled.contains { $0["id"] as? Int == 2 }, "a cancelled read has an answer: \(cancelled)")
    }
}
