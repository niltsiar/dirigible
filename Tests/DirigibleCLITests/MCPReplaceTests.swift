import DirigibleCore
import Foundation
import Testing

/// `clip_replace` with `source` (decision 0053, C12).
struct MCPReplaceTests {
    /// C12: under a split take, `clip_replace` with `source` gives the exit-3 text of the CLI as a
    /// tool error, and changes nothing.
    @Test func sourceSplitTakeIsAToolError() async throws {
        let fixture = try await PlaceCommandTests()
        let source = try PasteFromCommandTests.package(tone: true, track: "t1", rate: 48_000)
        let before = try fixture.package.xml()
        let cli = try await fixture.package.run(
            "clip", "replace", "PKG", "--source", source.path, "--track", "t1", "--from", "0", "--to", "24000", "--at",
            "0", "--until", "48000", "--onto", "t2")
        #expect(cli.status == 3)

        let answers = try await mcp([
            toolCall(
                1, "clip_replace",
                [
                    "package": fixture.package.path, "source": source.path, "track": ["t1"], "from": 0, "to": 24_000,
                    "at": 0, "until": 48_000, "onto": ["t2"],
                ])
        ])

        #expect(toolResult(answer(answers, id: 1)) == (errorText(cli), true))
        #expect(try fixture.package.xml() == before)
    }
}
