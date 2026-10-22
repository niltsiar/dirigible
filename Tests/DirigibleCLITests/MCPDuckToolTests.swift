import DirigibleCore
import Foundation
import Testing

/// The `duck` tool on the files (decision 0060, C16), on the package of `DuckCommandTests`.
struct MCPDuckToolTests {
    let fixture: DuckCommandTests

    init() throws { fixture = try DuckCommandTests() }

    var package: TemporaryPackage { fixture.package }

    /// The tool gives the lines and the report line of the command, and writes the same envelope.
    @Test func theToolDucksAsTheCommand() async throws {
        let answers = try await mcp([toolCall(1, "duck", ["package": package.path])])
        let text =
            "speech\t96000\t288000\nspeech\t576000\t768000\nducked\tcm\nSpeech runs: 2. Clips ducked: 1, with 8 points."
        #expect(toolResult(answer(answers, id: 1)) == (text, false))
        #expect(try package.read().clip("cm")?.clip.envelope.points.count == 8)
    }

    /// Silent speech is a tool error with the noSpeech text, and session.xml keeps its bytes.
    @Test func silentSpeechIsAToolError() async throws {
        try DuckCommandTests.write(package.url.appending(path: "Clips/speech.wav"), [(20, -50)])
        let before = try package.xml()
        let answers = try await mcp([toolCall(1, "duck", ["package": package.path])])
        let text = "no speech over -40.0 dBFS in the timeline frames 0..<960000, so the duck changed nothing."
        #expect(toolResult(answer(answers, id: 1)) == (text, true))
        #expect(try package.xml() == before)
    }

    /// A range that starts at the session end is a tool error, and session.xml keeps its bytes.
    @Test func aRangePastTheSessionEndIsAToolError() async throws {
        let before = try package.xml()
        let answers = try await mcp([
            toolCall(1, "duck", ["package": package.path, "from": 960_000, "to": 2_000_000])
        ])
        let text =
            "the range 960000..<2000000 starts at or after the session end at frame 960000, so the duck changed nothing."
        #expect(toolResult(answer(answers, id: 1)) == (text, true))
        #expect(try package.xml() == before)
    }

    /// A speech file that does not read: the text names it in an unread line and in the report.
    @Test func aSpeechFileThatDoesNotReadIsNamed() async throws {
        try DuckCommandTests.addMissingSpeech(package)
        let answers = try await mcp([toolCall(1, "duck", ["package": package.path])])
        let text =
            "speech\t96000\t288000\nspeech\t576000\t768000\nducked\tcm\nunread\tgone\nSpeech runs: 2. Clips ducked: 1, "
            + "with 8 points. Speech files that did not read: 1. The music stays up over their speech."
        #expect(toolResult(answer(answers, id: 1)) == (text, false))
    }

    /// A positive depth and a lone from are refused before the package is read.
    @Test func aBadArgumentIsAToolError() async throws {
        let answers = try await mcp([
            toolCall(1, "duck", ["package": package.path, "depth": 6]),
            toolCall(2, "duck", ["package": package.path, "from": 10]),
        ])
        #expect(
            toolResult(answer(answers, id: 1)) == ("depth and threshold are dB values under 0 and not under -96.", true)
        )
        #expect(
            toolResult(answer(answers, id: 2)) == (
                "from and to come together, as frames in 0...2^40 with from < to.", true
            ))
    }
}
