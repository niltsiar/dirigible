import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// `Studio.unusedFiles` and `Studio.removeUnusedFiles` (decision 0047, criteria C6b, C7, and C12
/// of run `2026-10-12-remove-unused-files`). Track t1 has clip A of file "used"; file `spare` has no
/// clip, and a stray WAV is in `Clips/`. The prune uses the real Trash: each test removes only the
/// Trash URLs of its report, and each file has a UUID name.
@MainActor
struct StudioPruneTests {
    let package: MixPackage
    let spare = FileID("spare-\(UUID().uuidString)")
    let stray = "stray-\(UUID().uuidString).wav"
    var clips: URL { package.url.appending(path: clipsFolderName) }

    init() throws {
        package = try MixPackage()
        try package.addFile("used", channels: [sine(seconds: 0.1, rate: 48_000)])
        try package.addFile(spare, channels: [sine(seconds: 0.1, rate: 48_000)])
        try package.addTrack("t1", clip: "A", file: "used", start: 0, offset: 0, length: 4_800)
        try package.session.write(to: package.url)
        try Data(count: 8).write(to: clips.appending(path: stray))
    }

    var spareName: String { "\(spare.rawValue).wav" }

    func open() async throws -> Studio {
        let studio = try await Studio.open(package.url)
        studio.environment = .test(TestHAL([]))
        return studio
    }

    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: clips.appending(path: name).path) }

    /// Removes the Trash item of each moved file of `report`, and only those.
    func cleanUp(_ report: PruneReport?) {
        for moved in report?.moved ?? [] { try? FileManager.default.removeItem(at: moved.trashURL) }
    }

    /// C12 control: an idle prune moves the files of the list, and session.xml has no pool entry.
    @Test func prunesAfterConfirmation() async throws {
        let studio = try await open()
        let scan = try await studio.unusedFiles()
        #expect(scan.items.map(\.path) == [spareName, stray].sorted())

        let report = try await studio.removeUnusedFiles(scan)
        defer { cleanUp(report) }

        #expect(report.moved.map(\.item.path) == [spareName, stray].sorted() && report.failed.isEmpty)
        #expect(!exists(spareName) && !exists(stray) && exists("used.wav"))
        #expect(studio.session.files[spare] == nil)
        #expect(try Session(contentsOf: package.url).files[spare] == nil, "session.xml has the prune")
        #expect(!studio.canUndo, "the prune is no undo entry")
        await studio.settle()
    }

    /// Storage gate item 1 (decision 0055): a prune of a file with words keeps the words state of
    /// its save, so the session in memory equals `session.xml` and the next save writes no second
    /// transcript file.
    @Test func aPruneOfAFileWithWordsKeepsTheSavedWords() async throws {
        try package.session.place(Clip(id: "S", file: spare, start: 4_800, offset: 0, length: 4_800), on: "t1")
        let words = #"{"words":[{"word":"one","start":0.01,"end":0.02},{"word":"two","start":0.11,"end":0.12}]}"#
        try package.session.importTranscript(TranscriptFile(data: Data(words.utf8)), name: "t", track: "t1", at: 0)
        try package.session.removeClips(["S"])
        try package.session.write(to: package.url)
        let studio = try await open()

        let report = try await studio.removeUnusedFiles(try await studio.unusedFiles())
        defer { cleanUp(report) }

        #expect(report.moved.map(\.item.path).contains(spareName))
        let saved = try Session(contentsOf: package.url)
        #expect(saved.words().map(\.text) == ["one"])
        let same = studio.session == saved
        #expect(same, "the session in memory has the words file of the save")
        await studio.settle()
    }

    /// C12: busy during an import and a level; nothing moves.
    @Test func busyRefused() async throws {
        let studio = try await open()
        let scan = try await studio.unusedFiles()
        try #require(scan.items.count == 2)

        for state in [
            Studio.Transport.importing(ImportRun(name: "x", kind: .file, flags: ImportFlags())), .leveling, .ducking,
        ] {
            studio.transport = state
            await #expect(throws: StudioError.busy) { try await studio.unusedFiles() }
            await #expect(throws: StudioError.busy) { try await studio.removeUnusedFiles(scan) }
        }
        studio.transport = .idle

        #expect(exists(spareName) && exists(stray) && studio.session.files[spare] != nil)
        await studio.settle()
    }

    /// C12: an edit after the list uses the spare file; it stays, and the stray WAV moves.
    @Test func editAfterScanKeepsNewlyUsedFile() async throws {
        let studio = try await open()
        let scan = try await studio.unusedFiles()
        let clip = Clip(id: "B", file: spare, start: 10_000, offset: 0, length: 4_800)
        try studio.edit(ripple: false) { session throws(SessionError) in try session.place(clip, on: "t1") }

        let report = try await studio.removeUnusedFiles(scan)
        defer { cleanUp(report) }

        #expect(report.moved.map(\.item.path) == [stray])
        #expect(exists(spareName) && studio.session.files[spare] != nil)
        await studio.settle()
    }

    /// C8 in a studio: a failed save moves no file and leaves the session as it was, and the
    /// error shows as the error of an autosave. Memory and disk do not split.
    @Test func saveFailureKeepsSession() async throws {
        let studio = try await open()
        studio.environment = .test(
            TestHAL([]),
            saveSession: { _, _ throws(SessionFileError) in throw .writeFailed(step: "write", errno: ENOSPC) })
        let scan = try await studio.unusedFiles()
        let (session, revision) = (studio.session, studio.sessionRevision)

        await #expect(throws: StudioError.unusedFiles(.save(.writeFailed(step: "write", errno: ENOSPC)))) {
            try await studio.removeUnusedFiles(scan)
        }

        #expect(studio.session == session && studio.sessionRevision == revision, "the pool entries stay")
        #expect(exists(spareName) && exists(stray))
        #expect(studio.saveError == .file(.writeFailed(step: "write", errno: ENOSPC)))
        await studio.settle()
    }

    /// C7: Undo and Redo after the prune bring back no pool entry of a moved file.
    @Test func undoAfterPruneHasNoMissingMedia() async throws {
        let studio = try await open()
        try studio.edit(ripple: false) { session throws(SessionError) in try session.renameTrack("t1", to: "Host") }
        let revision = studio.sessionRevision

        let report = try await studio.removeUnusedFiles(try await studio.unusedFiles())
        defer { cleanUp(report) }

        #expect(report.moved.count == 2)
        #expect(studio.sessionRevision == revision + 1 && studio.canUndo && !studio.canRedo)
        try studio.undo()
        #expect(studio.session.files[spare] == nil && studio.session.track("t1")?.name == "t1")
        await studio.checkMedia()
        #expect(studio.missingMedia.isEmpty, "\(studio.missingMedia)")
        try studio.redo()
        #expect(studio.session.files[spare] == nil && studio.session.track("t1")?.name == "Host")
        await studio.settle()
    }

    /// C6b: a clipboard of this package keeps the files of its clips; one of another package does not.
    @Test func keepsClipboardFiles() async throws {
        let studio = try await open()
        var copied = studio.session
        try copied.place(Clip(id: "B", file: spare, start: 10_000, offset: 0, length: 4_800), on: "t1")
        let excerpt = try copied.excerpt(of: ["B"])
        let own = Clipboard(excerpt, package: package.url, origin: studio.identity)
        let other = Clipboard(excerpt, package: package.url, origin: nil)

        let kept = try await studio.unusedFiles(clipboard: own)
        let listed = try await studio.unusedFiles(clipboard: other)

        #expect(kept.items.map(\.path) == [stray] && kept.kept.count == 1)
        #expect(listed.items.map(\.path) == [spareName, stray].sorted())
        let report = try await studio.removeUnusedFiles(listed, clipboard: own)
        defer { cleanUp(report) }
        #expect(report.moved.map(\.item.path) == [stray] && exists(spareName), "the new scan keeps the file")
        await studio.settle()
    }

    /// Review item 1: a prune that writes nothing keeps the error of a failed autosave, so the
    /// close still saves again.
    @Test func emptyPruneKeepsSaveError() async throws {
        let studio = try await open()
        let scan = try await studio.unusedFiles()
        studio.environment = .test(
            TestHAL([]),
            saveSession: { _, _ throws(SessionFileError) in throw .writeFailed(step: "write", errno: ENOSPC) })
        try FileManager.default.removeItem(at: clips.appending(path: stray))
        let clip = Clip(id: "B", file: spare, start: 10_000, offset: 0, length: 4_800)
        try studio.edit(ripple: false) { session throws(SessionError) in try session.place(clip, on: "t1") }

        let report = try await studio.removeUnusedFiles(scan)

        #expect(report.moved.isEmpty)
        #expect(studio.saveError == .file(.writeFailed(step: "write", errno: ENOSPC)), "only a write clears it")
        await studio.settle()
    }

    /// Review item 2: an edit during the prune save uses the spare file. No file moves, no save
    /// failed, and the autosave of the edit writes it.
    @Test func editDuringSaveMovesNothing() async throws {
        let studio = try await open()
        let scan = try await studio.unusedFiles()
        let clip = Clip(id: "B", file: spare, start: 10_000, offset: 0, length: 4_800)
        studio.environment = .test(
            TestHAL([]),
            saveSession: { session, lock throws(SessionFileError) in
                await MainActor.run {
                    _ = try? studio.edit(ripple: false) { s throws(SessionError) in try s.place(clip, on: "t1") }
                }
                return try session.write(under: lock)
            })

        await #expect(throws: StudioError.unusedFiles(.changedDuringPrune)) { try await studio.removeUnusedFiles(scan) }

        #expect(studio.saveError == nil, "the save did not fail")
        #expect(exists(spareName) && exists(stray) && studio.session.files[spare] != nil)
        await studio.settle()
        let saved = try Session(contentsOf: package.url)
        #expect(saved.files[spare] != nil && saved.track("t1")?.clips.contains { $0.id == "B" } == true)
    }

    /// Review item 3: an undo entry whose pool names a stray WAV with no clip loses that entry, so
    /// Undo brings back no pool entry of a file in the Trash.
    @Test func undoEntryLosesEntryOfMovedStray() async throws {
        let studio = try await open()
        try studio.edit(ripple: false) { session throws(SessionError) in try session.removeFile(spare) }
        let scan = try await studio.unusedFiles()
        #expect(scan.items.map(\.path) == [spareName, stray].sorted() && scan.items.allSatisfy { $0.kind == .stray })

        let report = try await studio.removeUnusedFiles(scan)
        defer { cleanUp(report) }

        #expect(report.moved.count == 2)
        try studio.undo()
        #expect(studio.session.files[spare] == nil, "no pool entry of a file in the Trash")
        await studio.settle()
    }

    /// Review item 8: the new scan reads the clipboard of its turn of the write chain.
    @Test func confirmationReadsClipboardOfItsTurn() async throws {
        let studio = try await open()
        var copied = studio.session
        try copied.place(Clip(id: "B", file: spare, start: 10_000, offset: 0, length: 4_800), on: "t1")
        let own = Clipboard(try copied.excerpt(of: ["B"]), package: package.url, origin: studio.identity)
        let listed = try await studio.unusedFiles()
        let gate = AsyncGate()
        studio.environment = .test(
            TestHAL([]),
            saveSession: { session, lock throws(SessionFileError) in
                await gate.wait()
                return try session.write(under: lock)
            })
        try studio.edit(ripple: false) { session throws(SessionError) in try session.renameTrack("t1", to: "Host") }
        await gate.entered()
        let box = ClipboardBox()

        let task = Task { try await studio.removeUnusedFiles(listed, clipboard: box.clipboard) }
        await until("the prune waits for its turn") { studio.writesWaiting > 0 }
        box.clipboard = own
        gate.open()
        let report = try await task.value
        defer { cleanUp(report) }

        #expect(report.moved.map(\.item.path) == [stray] && exists(spareName))
        await studio.settle()
    }

    @MainActor final class ClipboardBox { var clipboard: Clipboard? }
}
