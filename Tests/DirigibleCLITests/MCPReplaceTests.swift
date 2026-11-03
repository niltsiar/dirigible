import DirigibleCore
import Foundation
import Testing

/// `clip_replace` and `clip_fill` (decision 0053, C12, U41).
struct MCPReplaceTests {
    /// U41: a `clip_replace` of a clipboard of 0 frames gives the CLI exit-1 text as a tool error,
    /// and removes no audio.
    @Test func emptyClipboardIsAToolError() async throws {
        let package = try PasteFromCommandTests.package(tone: true, track: "t1", rate: 48_000)
        let before = try package.xml()

        let answers = try await mcp([
            toolCall(
                1, "clip_replace",
                ["package": package.path, "track": ["t1"], "from": 100, "to": 100, "at": 0, "until": 24_000])
        ])

        let result = toolResult(answer(answers, id: 1))
        #expect(result.isError && result.text.contains("the excerpt has no frames"), "\(result)")
        #expect(try package.xml() == before)
    }

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
