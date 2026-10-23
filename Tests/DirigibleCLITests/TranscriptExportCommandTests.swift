import Foundation
import Testing

/// `dirigible transcript export` (decision 0061, criteria C11 and C12 of run 2026-10-22-take-sync).
struct TranscriptExportCommandTests {
    let package: TemporaryPackage

    /// A Whisper-shaped SRT with times exact to the millisecond: the export of a session with no
    /// edit gives these bytes.
    static let srt =
        "1\n00:00:01,000 --> 00:00:03,500\nHello there.\n\n2\n00:00:03,500 --> 00:00:05,120\nHow are you?\n\n"
        + "3\n00:00:50,004 --> 00:00:51,000\nFine, thanks.\n"

    init() throws { package = try TemporaryPackage(TranscriptCommandTests.session()) }

    /// Imports `text` as a file named `name` on the track `host`.
    func importText(_ text: String, name: String = "t.srt") async throws {
        let file = package.folder.appending(path: name)
        try Data(text.utf8).write(to: file)
        let result = try await package.run("transcript", "import", "PKG", file.path, "--track", "host")
        try #require(result.status == 0, "transcript import: \(result)")
    }

    /// Exports to `name` in the folder of the package, and gives the result and the file text.
    func export(_ name: String, _ more: String...) async throws -> (result: CLIResult, text: String?) {
        let out = package.folder.appending(path: name)
        let result = try await package.run(["transcript", "export", "PKG", "--out", out.path] + more)
        return (result, try? String(contentsOf: out, encoding: .utf8))
    }

    func clip(_ arguments: String...) async throws {
        let result = try await package.run(["clip"] + arguments)
        try #require(result.status == 0, "clip \(arguments): \(result)")
    }

    /// C11. An SRT that was imported exports the same cues, with no edit.
    @Test func anImportedSRTExportsTheSameCues() async throws {
        try await importText(Self.srt)

        let exported = try await export("out.srt")

        #expect(exported.result == CLIResult(status: 0, stdout: "", stderr: ""), "\(exported.result)")
        #expect(exported.text == Self.srt)
    }

    /// C11. A ripple insert of 5 s at 0 moves each cue 5000 ms.
    @Test func aRippleInsertShiftsEachCue() async throws {
        try await importText(Self.srt)
        try await clip("ripple-insert", "PKG", "--at", "0", "--length", "240000")

        let exported = try await export("out.srt")

        #expect(
            exported.text
                == "1\n00:00:06,000 --> 00:00:08,500\nHello there.\n\n2\n00:00:08,500 --> 00:00:10,120\nHow are you?\n\n"
                + "3\n00:00:55,004 --> 00:00:56,000\nFine, thanks.\n")
    }

    /// C11. A ripple delete of 3 s to 4 s cuts the audio of the second cue: the first cue ends at
    /// the cut, the second starts there, and the third moves 1000 ms earlier.
    @Test func aCutThroughACueClampsIt() async throws {
        try await importText(Self.srt)
        try await clip("ripple-delete", "PKG", "--from", "144000", "--to", "192000")

        let exported = try await export("out.srt")

        #expect(
            exported.text
                == "1\n00:00:01,000 --> 00:00:03,000\nHello there.\n\n2\n00:00:03,000 --> 00:00:04,120\nHow are you?\n\n"
                + "3\n00:00:49,004 --> 00:00:50,000\nFine, thanks.\n")
    }

    /// C11. The extension picks WebVTT. A text with `&`, `<`, or `-->` is safe in both forms.
    @Test func theVTTForm() async throws {
        try await importText(
            #"{"words":[{"word":"R&B","start":1,"end":2},{"word":"1<2","start":3,"end":4},"#
                + #"{"word":"a-->b","start":5,"end":6}]}"#, name: "t.json")

        let vtt = try await export("out.vtt")
        let srt = try await export("out.srt")

        #expect(
            vtt.text
                == "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nR&amp;B\n\n00:00:03.000 --> 00:00:04.000\n1&lt;2\n\n"
                + "00:00:05.000 --> 00:00:06.000\na-&gt;b\n")
        #expect(
            srt.text
                == "1\n00:00:01,000 --> 00:00:02,000\nR&B\n\n2\n00:00:03,000 --> 00:00:04,000\n1<2\n\n"
                + "3\n00:00:05,000 --> 00:00:06,000\na->b\n")
    }

    /// C11. Two transcripts with no `--transcript` exit 1 and list the IDs; `--transcript` picks one.
    @Test func twoTranscriptsNeedTheOption() async throws {
        try await importText(Self.srt)
        try await importText("1\n00:01:00,000 --> 00:01:02,000\nAnother.\n", name: "u.srt")

        let none = try await export("out.srt")
        let second = try await export("two.srt", "--transcript", "2")
        let unknown = try await export("three.srt", "--transcript", "3")

        #expect(
            none.result
                == CLIResult(
                    status: 1, stdout: "",
                    stderr: "Error: The session has transcripts 1, 2. Give --transcript <id>.\n"), "\(none)")
        #expect(none.text == nil)
        #expect(second.text == "1\n00:01:00,000 --> 00:01:02,000\nAnother.\n")
        #expect(
            unknown.result
                == CLIResult(status: 1, stdout: "", stderr: "Error: The session has no transcript 3.\n"))
    }

    /// C11. An extension that is not .srt or .vtt exits 64, a session with no transcript exits 1, and
    /// a path inside a session package exits 64. None writes a file.
    @Test func theRefusals() async throws {
        let text = try await export("out.txt")
        let none = try await export("out.srt")
        try await importText(Self.srt)
        let inside = try await package.run(
            "transcript", "export", "PKG", "--out", package.url.appending(path: "out.srt").path)

        #expect(text.result.status == 64 && text.result.stderr.contains("--out must end in .srt or .vtt."), "\(text)")
        #expect(
            none.result == CLIResult(status: 1, stdout: "", stderr: "Error: The session has no transcript.\n"))
        #expect(inside.status == 64 && inside.stderr.contains("must be outside the session package"), "\(inside)")
        #expect(text.text == nil && none.text == nil)
        #expect(!FileManager.default.fileExists(atPath: package.url.appending(path: "out.srt").path))
    }

    /// C12. An existing file is refused unless `--replace`: the old bytes stay. Control: with
    /// `--replace` the new cues replace them.
    @Test func anExistingFileIsRefusedUnlessReplace() async throws {
        try await importText(Self.srt)
        let out = package.folder.appending(path: "out.srt")
        try Data("old".utf8).write(to: out)

        let refused = try await export("out.srt")
        let replaced = try await export("out.srt", "--replace")

        #expect(refused.result == CLIResult(status: 2, stdout: "", stderr: "Error: \(out.path) exists.\n"))
        #expect(replaced.result.status == 0 && replaced.text == Self.srt, "\(replaced)")
    }
}
