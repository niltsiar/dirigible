import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing
import os

@testable import DirigibleApp
@testable import DirigibleAudio

/// File > Export Chapters (run 2026-10-09-chapters-export, criteria C14 to C18) on a real session
/// window of 10 s. The save panel is a stub that gives a URL in the test folder.
extension ExportWindowTests {
    /// The start times of a chapters file.
    func startTimes(_ url: URL) throws -> [Double] {
        let file = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try #require(file["chapters"] as? [[String: Any]]).compactMap { $0["startTime"] as? Double }
    }

    func addChapter(at position: Frames, _ studio: Studio) throws {
        try studio.edit { session throws(SessionError) in
            try session.setMarker(Marker(id: MarkerID(), name: "Chapter", position: position, kind: .chapter))
        }
    }

    /// The panel stub: it keeps the name and the message, and answers `url`.
    func chaptersPanel(_ url: URL?) -> OSAllocatedUnfairLock<[(String, String?)]> {
        let calls = OSAllocatedUnfairLock<[(String, String?)]>(initialState: [])
        app.chooseChaptersExport = { _, name, message, done in
            calls.withLock { $0.append((name, message)) }
            done(url)
        }
        return calls
    }

    /// C14. Each start state of the item.
    @Test func theItemFollowsTheChapters() async throws {
        let (model, studio, _) = try await window()
        #expect(!model.isOn(.exportChapters), "no chapter")
        try addChapter(at: 240_000, studio)
        #expect(model.isOn(.exportChapters), "a chapter, no Marks")
        model.timeline.marks = Marks(inPoint: 0, outPoint: 48_000, tracks: ["t1"])
        #expect(!model.isOn(.exportChapters), "the Marks on a range with no chapter, a chapter outside")
        model.timeline.marks = nil
        model.exportStep = .checking
        #expect(!model.isOn(.exportChapters), "an export step")
        model.exportStep = nil
        await model.close()
    }

    /// Code gate item 1. A chapter at or after the session end is past the audio: the item is off,
    /// also when the session has no clip.
    @Test func aChapterPastTheAudioLeavesTheItemOff() async throws {
        let (model, studio, _) = try await window()
        try addChapter(at: 480_000, studio)
        #expect(!model.isOn(.exportChapters), "a chapter at the session end")
        try studio.edit { session throws(SessionError) in try session.removeClips(["c1"]) }
        #expect(studio.session.end == .zero)
        #expect(!model.isOn(.exportChapters), "no clip")
        await model.close()
    }

    /// C15, the release-line test. Control: the range 0..<end gives 4, not 2.
    @Test func exportSelectionRangeGivesTheOffset() async throws {
        let file = folder.url.appending(path: "chosen.json")
        let calls = chaptersPanel(file)
        let (model, studio, _) = try await window()
        try addChapter(at: 192_000, studio)
        model.timeline.marks = Marks(inPoint: 96_000, outPoint: 384_000, tracks: ["t1"])
        model.run(.exportChapters)
        await until("the file is written") { FileManager.default.fileExists(atPath: file.path) }
        #expect(try startTimes(file) == [2])
        let call = try #require(calls.withLock { $0 }.first)
        #expect(call.0 == "timeline.chapters.json" && call.1 == L10n.panelChaptersMarks.text)
        #expect(model.exportStep == nil && model.alert == nil)
        await model.close()
    }

    /// C16. No Marks, and the Marks with no selected track, give the whole session and no message.
    @Test func noMarksGivesTheWholeSessionAndNoMessage() async throws {
        let (first, second) = (folder.url.appending(path: "a.json"), folder.url.appending(path: "b.json"))
        let calls = chaptersPanel(first)
        let (model, studio, _) = try await window()
        try addChapter(at: 192_000, studio)
        model.exportChapters()
        await until("the first file is written") { FileManager.default.fileExists(atPath: first.path) }
        _ = chaptersPanel(second)
        model.timeline.marks = Marks(inPoint: 96_000, outPoint: 384_000, tracks: [])
        model.exportChapters()
        await until("the second file is written") { FileManager.default.fileExists(atPath: second.path) }
        #expect(try startTimes(first) == [4] && startTimes(second) == [4])
        #expect(calls.withLock { $0 }.map(\.1) == [nil])
        await model.close()
    }

    /// C17.
    @Test func aCancelWritesNothing() async throws {
        let calls = chaptersPanel(nil)
        let (model, studio, _) = try await window()
        try addChapter(at: 192_000, studio)
        let before = try FileManager.default.contentsOfDirectory(atPath: folder.url.path)
        model.exportChapters()
        #expect(calls.withLock { $0.count } == 1, "the panel showed")
        #expect(model.exportStep == nil && model.alert == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path) == before)
        await model.close()
    }

    /// C18. The errno under the CocoaError is the key, not the Cocoa code (probe-errno).
    @Test func writeErrorsKeepTheErrnoUnit() {
        let full = CocoaError(.fileWriteUnknown, userInfo: [NSUnderlyingErrorKey: POSIXError(.ENOSPC)])
        #expect(ExportError(writing: full) == .diskFull)
        let denied = CocoaError(.fileWriteNoPermission, userInfo: [NSUnderlyingErrorKey: POSIXError(.EACCES)])
        #expect(ExportError(writing: denied) == .moveFailed(EACCES))
        #expect(ExportError(writing: CocoaError(.fileWriteUnknown)) == .moveFailed(EIO))
    }

    /// C18. A folder that does not exist gives errno ENOENT (probe-errno), so the move alert.
    @Test func aMissingFolderShowsTheMoveAlert() async throws {
        _ = chaptersPanel(folder.url.appending(path: "gone/x.json"))
        let (model, studio, _) = try await window()
        try addChapter(at: 192_000, studio)
        model.exportChapters()
        await until("the alert shows") { model.alert != nil }
        #expect(model.alert == .error(.export(.moveFailed(ENOENT))))
        await model.close()
    }
}
