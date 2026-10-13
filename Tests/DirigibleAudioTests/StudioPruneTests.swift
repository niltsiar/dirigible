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

    /// C12: busy during an import and a level; nothing moves.
    @Test func busyRefused() async throws {
        let studio = try await open()
        let scan = try await studio.unusedFiles()
        try #require(scan.items.count == 2)

        for state in [Studio.Transport.importing(ImportRun(name: "x", kind: .file, flags: ImportFlags())), .leveling] {
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
        try studio.edit { session throws(SessionError) in try session.place(clip, on: "t1") }

        let report = try await studio.removeUnusedFiles(scan)
        defer { cleanUp(report) }

        #expect(report.moved.map(\.item.path) == [stray])
        #expect(exists(spareName) && studio.session.files[spare] != nil)
        await studio.settle()
    }

    /// C7: Undo and Redo after the prune bring back no pool entry of a moved file.
    @Test func undoAfterPruneHasNoMissingMedia() async throws {
        let studio = try await open()
        try studio.edit { session throws(SessionError) in try session.renameTrack("t1", to: "Host") }
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
}
