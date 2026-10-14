import DirigibleCore
import Foundation
import Testing

/// The `level` tool of `dirigible mcp` on the files (decision 0049). The package of
/// `LevelCommandTests`; the tool and the command each get their own copy, because both write.
struct MCPLevelToolTests {
    /// The stdout lines and then the stderr line of a run, or the error line.
    private func text(of run: CLIResult) -> (text: String, isError: Bool) {
        guard run.status == 0 else { return (errorText(run), true) }
        return ((run.stdout + run.stderr).split(separator: "\n").joined(separator: "\n"), false)
    }

    /// C13: the tool gives the lines and the report line of `dirigible level`, and its refusals.
    @Test func theToolTextIsTheCommandText() async throws {
        let cases: [(cli: [String], tool: [String: Any])] = [
            ([], [:]),
            (["loud", "quiet", "--per-track"], ["clips": ["loud", "quiet"], "per_track": true]),
            (["loud", "nope"], ["clips": ["loud", "nope"]]),
        ]
        for (index, item) in cases.enumerated() {
            let (cli, tool) = (try LevelCommandTests.package(), try LevelCommandTests.package())
            let run = try await cli.run(["level", "PKG"] + item.cli)
            let answers = try await mcp([
                toolCall(1, "level", item.tool.merging(["package": tool.path]) { $1 })
            ])
            #expect(toolResult(answer(answers, id: 1)) == text(of: run), "case \(index): \(run)")
            #expect(try tool.xml() == cli.xml(), "case \(index): the tool and the command wrote the same session")
        }
    }

    /// A second level changes no gain, so it gives the no-change line and writes nothing.
    @Test func aSecondLevelGivesTheNoChangeLine() async throws {
        let package = try LevelCommandTests.package()
        let first = try await mcp([toolCall(1, "level", ["package": package.path])])
        #expect(toolResult(answer(first, id: 1)).isError == false)
        let before = try package.xml()
        let second = try await mcp([toolCall(1, "level", ["package": package.path, "clips": ["loud"]])])
        #expect(
            toolResult(answer(second, id: 1)) == ("loud\t+7.0 dB\nNo change: the clips are at the target level.", false)
        )
        #expect(try package.xml() == before, "a level with no change wrote session.xml")
    }

    /// A cancel leaves `session.xml` byte for byte as it was, and the call gets no answer.
    @Test func aCancelEndsTheLevel() async throws {
        let package = try LevelCommandTests.package()
        let before = try package.xml()
        let lines = try await mcpLines([
            toolCall(2, "level", ["package": package.path], token: 1), cancelLine(2), modernRequest(3, "ping"),
        ])
        #expect(lines.contains { $0["id"] as? Int == 3 }, "the ping after the cancel has its answer: \(lines)")
        #expect(!lines.contains { $0["id"] as? Int == 2 }, "a cancelled level has no answer: \(lines)")
        #expect(try package.xml() == before, "a cancelled level changed session.xml")
    }

    /// C1: the arguments are the options of the command, with `_` for `-`, and the CLI defaults.
    @Test func theArgumentsAreTheOptions() async throws {
        let answers = try await mcp([modernRequest(1, "tools/list")])
        let tools = result(answer(answers, id: 1))["tools"] as? [[String: Any]] ?? []
        let schema = tools.first { $0["name"] as? String == "level" }?["inputSchema"] as? [String: Any] ?? [:]
        let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
        #expect(Set(properties.keys) == ["package", "clips", "per_track"], "\(properties.keys)")
        #expect(properties["per_track"]?["default"] as? Bool == false)
        #expect((schema["required"] as? [String]) == ["package"])
    }
}
