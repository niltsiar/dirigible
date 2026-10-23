import AppKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio
@testable import DirigibleMCP

/// File > Export Transcript (run 2026-10-22-take-sync, C16) on a real session window of 10 s. The
/// save panel is a stub that keeps its answer until the test gives it, as the panel waits for Save.
/// The file of the command is the one that `TranscriptExportWork` writes with the CLI spelling: the
/// render and the write of `dirigible transcript export`, after `Session(contentsOf:)` of the package.
@Suite(.serialized) @MainActor struct TranscriptExportMenuTests {
    /// One call of the save panel: the default name, the transcripts, and its answer.
    struct PanelCall {
        let name: String
        let transcripts: [String]
        let answer: @MainActor (TranscriptTarget?) -> Void
    }

    @MainActor final class Panel {
        var calls: [PanelCall] = []
    }

    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)
    let panel = Panel()

    init() throws {
        NSWindow.allowsAutomaticWindowTabbing = false
        folder = try TemporaryFolder()
        let panel = panel
        app.chooseTranscriptExport = { _, name, transcripts, done in
            panel.calls.append(
                PanelCall(name: name, transcripts: transcripts.map { "\($0.id.number) \($0.name)" }, answer: done))
        }
    }

    /// The Whisper words of the transcript `Host` (0.01 s to 0.02 s) and `Guest` (5.01 s to 5.5 s).
    static let host = #"{"words":[{"word":"one","start":0.01,"end":0.02},{"word":"two","start":0.11,"end":0.12}]}"#
    static let guest = #"{"words":[{"word":"guest","start":5.01,"end":5.5}]}"#

    func importTranscript(_ name: String, _ words: String, into session: inout Session) throws {
        try session.importTranscript(TranscriptFile(data: Data(words.utf8)), name: name, track: "t1", at: 0)
    }

    /// A window of a package with track `t1`, a clip of 10 s, and the transcripts.
    func window(_ transcripts: [(String, String)] = [("Host", host)]) async throws -> (SessionWindow, Studio, URL) {
        let package = try await timelinePackage(in: folder.url, tracks: 1, seconds: 10, audio: true)
        var session = try Session(contentsOf: package)
        for (name, words) in transcripts { try importTranscript(name, words, into: &session) }
        try session.write(to: package)
        let model = await app.open(package)
        let studio = try #require(await model.opened() ? model.studio : nil)
        return (model, studio, package)
    }

    /// The file of `dirigible transcript export <package> --out <out> [--transcript <n>]`.
    func commandFile(_ package: URL, _ out: String, transcript: Int? = nil) throws -> Data {
        let url = folder.url.appending(path: out)
        _ = try TranscriptExportWork(out: url.path, transcript: transcript, replace: false, spelling: .cli)
            .run(package, path: package.path)
        return try Data(contentsOf: url)
    }

    /// C16, the first test. An agent inserts 1 s at 0 while the panel shows: the file has the
    /// session of the Save click. Control: the session of the panel open gives the old times.
    @Test func theMenuWritesTheFileOfTheCommand() async throws {
        let (model, studio, package) = try await window()
        let file = folder.url.appending(path: "chosen.srt")
        model.run(.exportTranscript)
        let call = try #require(panel.calls.first, "the panel showed")
        #expect(call.name == "timeline" && call.transcripts == ["1 Host"])
        let agent = AgentName(title: "Claude Code", clientName: "claude-code")
        try studio.edit(ripple: true, agent: agent) { session throws(SessionError) in
            try session.rippleInsert(48_000, at: 0, on: ["t1"])
        }
        call.answer(TranscriptTarget(url: file, format: .srt, transcript: 1))
        await until("the file is written") { FileManager.default.fileExists(atPath: file.path) }
        await studio.serialized {}
        let (written, command) = (try Data(contentsOf: file), try commandFile(package, "command.srt"))
        #expect(written == command, "the bytes of transcript export")
        let text = String(decoding: written, as: UTF8.self)
        #expect(text == "1\n00:00:01,010 --> 00:00:01,020\none\n\n2\n00:00:01,110 --> 00:00:01,120\ntwo\n")
        #expect(model.exportStep == nil && model.alert == nil)
        await model.close()
    }

    /// C16. Each start state of the item: no transcript, a transcript, an export step, the panel.
    @Test func theItemFollowsTheTranscripts() async throws {
        let (model, studio, _) = try await window([])
        #expect(!model.isOn(.exportTranscript), "no transcript")
        let host = try TranscriptFile(data: Data(Self.host.utf8))
        _ = try studio.edit(ripple: false) { session throws(SessionError) in
            try session.importTranscript(host, name: "Host", track: "t1", at: 0)
        }
        #expect(model.isOn(.exportTranscript), "a transcript")
        model.exportStep = .checking
        #expect(!model.isOn(.exportTranscript), "an export step")
        model.exportStep = nil
        model.run(.exportTranscript)
        #expect(panel.calls.count == 1 && model.exportStep == .choosing)
        #expect(!model.isOn(.exportTranscript) && !model.isOn(.exportChapters), "the panel shows")
        try #require(panel.calls.first).answer(nil)
        #expect(model.isOn(.exportTranscript), "after Cancel")
        await model.close()
    }

    /// C16. Two transcripts give the transcript pop-up, and the VTT form and transcript 2 give the
    /// file of `--out x.vtt --transcript 2`.
    @Test func thePopupsPickTheFormAndTheTranscript() async throws {
        let (model, _, package) = try await window([("Host", Self.host), ("Guest", Self.guest)])
        let file = folder.url.appending(path: "chosen.vtt")
        model.run(.exportTranscript)
        let call = try #require(panel.calls.first, "the panel showed")
        #expect(call.transcripts == ["1 Host", "2 Guest"])
        call.answer(TranscriptTarget(url: file, format: .vtt, transcript: 2))
        await until("the file is written") { FileManager.default.fileExists(atPath: file.path) }
        let written = try Data(contentsOf: file)
        #expect(written == (try commandFile(package, "command.vtt", transcript: 2)), "the bytes of transcript export")
        #expect(String(decoding: written, as: UTF8.self) == "WEBVTT\n\n00:00:05.010 --> 00:00:05.500\nguest\n")
        await model.close()
    }

    /// C16. The save panel asks before it replaces a file: while it shows, and after Cancel, the old
    /// bytes stay. Save after the confirm replaces them.
    @Test func aFileIsReplacedOnlyAfterTheConfirm() async throws {
        let (model, _, _) = try await window()
        let file = folder.url.appending(path: "chosen.srt")
        let old = Data("old subtitles\n".utf8)
        try old.write(to: file)
        model.run(.exportTranscript)
        #expect(panel.calls.count == 1, "the panel shows")
        #expect((try Data(contentsOf: file)) == old, "the panel shows")
        try #require(panel.calls.first).answer(nil)
        #expect(model.exportStep == nil && model.alert == nil)
        #expect((try Data(contentsOf: file)) == old, "after Cancel")
        model.run(.exportTranscript)
        #expect((try Data(contentsOf: file)) == old, "the second panel shows")
        #expect(panel.calls.count == 2, "the second panel showed")
        try #require(panel.calls.last).answer(TranscriptTarget(url: file, format: .srt, transcript: 1))
        await until("the file is replaced") { (try? Data(contentsOf: file)) != old }
        #expect(String(decoding: try Data(contentsOf: file), as: UTF8.self).hasPrefix("1\n00:00:00,010 --> "))
        await model.close()
    }

    /// A Cancel writes no file: after it and a later export, the folder has only one new file.
    @Test func aCancelWritesNoFile() async throws {
        let (model, _, _) = try await window()
        let other = folder.url.appending(path: "other.srt")
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: folder.url.path))
        model.run(.exportTranscript)
        try #require(panel.calls.first).answer(nil)
        model.run(.exportTranscript)
        try #require(panel.calls.count == 2, "the second panel showed")
        try #require(panel.calls.last).answer(TranscriptTarget(url: other, format: .srt, transcript: 1))
        await until("the file is written") { FileManager.default.fileExists(atPath: other.path) }
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: folder.url.path))
        #expect(after.subtracting(before) == ["other.srt"], "a Cancel writes no file")
        await model.close()
    }

    /// The replace renames a new file over the old one, so a failed write cannot cut the old file:
    /// a hard link to the old file keeps its bytes.
    @Test func aReplaceLeavesTheOldFileWhole() async throws {
        let (model, _, _) = try await window()
        let file = folder.url.appending(path: "chosen.srt")
        let link = folder.url.appending(path: "link.srt")
        let old = Data("old subtitles\n".utf8)
        try old.write(to: file)
        try FileManager.default.linkItem(at: file, to: link)
        model.run(.exportTranscript)
        try #require(panel.calls.first).answer(TranscriptTarget(url: file, format: .srt, transcript: 1))
        await until("the file is replaced") { (try? Data(contentsOf: file)) != old }
        #expect((try Data(contentsOf: link)) == old, "the old file is never written in place")
        await model.close()
    }

    /// A failed write shows the move alert with the errno, and writes no file.
    @Test func aFailedWriteShowsTheAlert() async throws {
        let (model, _, _) = try await window()
        let file = folder.url.appending(path: "gone/chosen.srt")
        model.run(.exportTranscript)
        try #require(panel.calls.first).answer(TranscriptTarget(url: file, format: .srt, transcript: 1))
        await until("the alert shows") { model.alert != nil }
        #expect(model.alert == .transcriptExport(.write(.moveFailed(ENOENT))))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        await model.close()
    }

    /// Code gate L3 item 2. A word with no length is left out of the file, as the command leaves
    /// it out, and a banner gives the count until the next change of the session.
    @Test func aWordWithNoLengthShowsTheBanner() async throws {
        let words = #"{"words":[{"word":"one","start":0.01,"end":0.02},{"word":"none","start":0.05,"end":0.05}]}"#
        let (model, studio, package) = try await window([("Host", words)])
        let file = folder.url.appending(path: "chosen.srt")
        model.run(.exportTranscript)
        try #require(panel.calls.first).answer(TranscriptTarget(url: file, format: .srt, transcript: 1))
        let banners = { ChromeState(model: model).shown.banners.filter { $0.key == "transcriptLeftOut" } }
        await until(limit: .seconds(10), "the banner shows") { !banners().isEmpty }
        #expect(banners() == [.transcriptLeftOut(count: 1, file: "chosen.srt")])
        #expect((try Data(contentsOf: file)) == (try commandFile(package, "command.srt")), "the file of the command")

        try studio.edit(ripple: true) { session throws(SessionError) in
            try session.rippleInsert(48_000, at: 0, on: ["t1"])
        }

        #expect(banners() == [], "the next change of the session hides it")
        await model.close()
    }
}
