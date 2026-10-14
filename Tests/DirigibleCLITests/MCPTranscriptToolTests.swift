import DirigibleCore
import Foundation
import Testing

/// The tools `transcript_import`, `transcript_words`, and `transcript_cut` (run transcript-1,
/// criteria T3, T11, T17, and T21).
struct MCPTranscriptToolTests {
    var fixture: String { TranscriptCommandTests.fixture.path }

    /// A copy of the fixture of `TranscriptCommandTests`.
    func package() throws -> TemporaryPackage { try TemporaryPackage(TranscriptCommandTests.session()) }

    /// The text of each tool call, in order, on `package`.
    func call(_ calls: [(String, [String: Any])], on package: TemporaryPackage) async throws -> [(
        text: String, isError: Bool
    )] {
        let answers = try await mcp(
            calls.enumerated().map { index, call in
                toolCall(index, call.0, call.1.merging(["package": package.path]) { $1 })
            })
        return calls.indices.map { toolResult(answer(answers, id: $0)) }
    }

    /// T17: each tool gives the text of its command (stdout, then stderr) and the same session.xml.
    @Test func toolsGiveTheCommandTexts() async throws {
        let (tool, cli) = (try package(), try package())
        let match = "Sorry, let me say that again."
        let imported = try await call(
            [("transcript_import", ["path": fixture, "track": "host"]), ("transcript_words", ["match": match])],
            on: tool)
        let cliImport = try await cli.run("transcript", "import", "PKG", fixture, "--track", "host")
        let cliWords = try await cli.run("transcript", "words", "PKG", "--match", match)
        #expect(imported.map(\.text) == [cliImport.stdout, cliWords.stdout].map { String($0.dropLast()) })
        let named = TranscriptCommandTests.occurrences(cliWords)
        #expect(named.count == 6)

        let cut = try await call([("transcript_cut", ["occurrences": named])], on: tool)
        let cliCut = try await cli.run(["transcript", "cut", "PKG"] + named)
        #expect(cut.map(\.text) == [String(cliCut.stdout.dropLast())] && !cut[0].isError)
        #expect(try tool.holdsTheSameSession(as: cli), "the tools and the commands give the same session.xml")

        let stale = try await call([("transcript_cut", ["occurrences": named])], on: tool)
        let cliStale = try await cli.run(["transcript", "cut", "PKG"] + named)
        #expect(stale.map(\.text) == [errorText(cliStale)] && stale[0].isError)
        let malformed = try await call([("transcript_cut", ["occurrences": ["x"]])], on: tool)
        #expect(malformed[0].isError && malformed[0].text.contains("x is not a word"), "\(malformed)")
    }

    /// T21: the fixture as text imports the words of the path; the name is `name`, else
    /// `transcript`.
    @Test func textImportEqualsPathImport() async throws {
        let (byPath, byText, unnamed) = (try package(), try package(), try package())
        let text = try String(contentsOfFile: fixture, encoding: .utf8)
        let results = [
            try await call([("transcript_import", ["path": fixture, "track": "host"])], on: byPath),
            try await call(
                [("transcript_import", ["text": text, "track": "host", "name": "agent-transcript.json"])], on: byText),
            try await call([("transcript_import", ["text": text, "track": "host"])], on: unnamed),
        ]
        #expect(results.map { $0[0].text } == Array(repeating: "1\nImported 95 words.", count: 3))
        #expect(try byPath.holdsTheSameSession(as: byText), "the text and the path give the same session.xml")
        let xml = String(decoding: try unnamed.xml(), as: UTF8.self)
        #expect(xml.contains(#"<transcript id="1" name="transcript" file=""#))
    }

    /// T21: both `path` and `text`, or neither, is refused with no change; a bad file names its
    /// reason (T3).
    @Test func pathAndTextAreRefused() async throws {
        let package = try package()
        let before = try package.xml()
        let results = try await call(
            [
                ("transcript_import", ["path": fixture, "text": "WEBVTT", "track": "host"]),
                ("transcript_import", ["track": "host"]),
                ("transcript_import", ["text": "nothing", "track": "host"]),
            ], on: package)
        #expect(
            results.map(\.text) == [
                "Give path or text, not both.", "Give path or text.",
                "text: the file is neither WebVTT nor Whisper JSON.",
            ])
        #expect(results.allSatisfy { $0.isError })
        #expect(try package.xml() == before)
    }

    /// T21: a text of 262 144 bytes imports; 262 145 bytes is refused with the next step.
    @Test func textOverTheCapIsRefused() async throws {
        let package = try package()
        let body = #"{"words":[{"word":"a","start":1,"end":2}]}"#
        let fits = body + String(repeating: " ", count: 262_144 - body.utf8.count)
        let results = try await call(
            [
                ("transcript_import", ["text": fits + " ", "track": "host"]),
                ("transcript_import", ["text": fits, "track": "host"]),
            ], on: package)
        #expect(results[0].text == "The text is over 256 KiB. Give the path of the file." && results[0].isError)
        #expect(results[1].text == "1\nImported 1 word." && !results[1].isError)
    }
}
