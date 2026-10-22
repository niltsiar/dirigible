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
