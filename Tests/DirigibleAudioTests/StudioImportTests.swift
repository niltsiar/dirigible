import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// A package with track t1 and clip c1 (1 s of tone), and a source file next to it.
struct ImportStudioFixture {
    let package: MixPackage
    let source: URL
    var url: URL { package.url }

    /// Writes the package and the source off the main actor. The source is `seconds` of a sine
    /// at `rate` Hz: 4 s at 44.1 kHz read in 3 blocks.
    @concurrent nonisolated static func make(seconds: Double = 4, rate: Int = 44_100) async throws
        -> sending ImportStudioFixture
    {
        let package = try MixPackage()
        try package.addFile("f1", channels: [sine(seconds: 1, rate: 48_000)])
        try package.addTrack("t1", clip: "c1", file: "f1", start: 0, offset: 0, length: 48_000)
        try package.session.write(to: package.url)
        let source = package.folder.url.appending(path: "Voice.wav")
        try writeSource(source, .wav16, rate: rate, channels: [sine(seconds: seconds, rate: Double(rate))])
        return ImportStudioFixture(package: package, source: source)
    }

    /// Opens the studio with the test environment. `step` runs at each cancel check of an import.
    @MainActor func open(
        _ hal: TestHAL = TestHAL([]), step: ChunkSeam = ChunkSeam(), peakCache: URL? = nil
    ) async throws -> Studio {
        let studio = try await Studio.open(url, peakCache: peakCache)
        studio.environment = .test(hal)
        studio.environment.importStep = { step.step() }
        return studio
    }

    var xml: Data? { FileManager.default.contents(atPath: url.appending(path: "session.xml").path) }
    var clipsNames: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.appending(path: clipsFolderName).path)) ?? [])
            .sorted()
    }
}

/// The progress values that an import gives, on the main actor.
@MainActor final class ProgressValues {
    var list: [Double] = []
}

/// `Studio.importAudio` (decision 0040): one undo entry, busy, cancel, settle, and the yield to a
/// take in another studio.
@MainActor
struct StudioImportTests {
    let newTrack = ImportTarget(track: nil, start: 96_000)

    @Test func anImportIsOneUndoEntryAndKeepsTheFile() async throws {
        let fixture = try await ImportStudioFixture.make()
        let studio = try await fixture.open()

        let clip = try await studio.importAudio(fixture.source, to: newTrack) { _ in }

        #expect(clip == "Voice")
        let saved = try Session(contentsOf: fixture.url)
        #expect(saved == studio.session, "session.xml has the import")
        #expect(saved.clip(clip)?.clip.start == 96_000 && saved.files["Voice"] != nil && saved.tracks.count == 2)
        try studio.undo()
        #expect(studio.session.clip(clip) == nil && studio.session.files["Voice"] == nil, "Undo removes the clip")
        #expect(studio.session.tracks.count == 1, "Undo removes the new track")
        #expect(!studio.canUndo, "the import is one undo entry")
        let url = fixture.url
        await until(limit: .seconds(10), "Undo is not saved") { (try? Session(contentsOf: url))?.files.count == 1 }
        #expect(fixture.clipsNames == ["Voice.wav", "f1.wav"], "the WAV stays after Undo")
        try studio.redo()
        #expect(studio.session == saved, "Redo brings the import back")
    }

    @Test func anImportIsBusyAndStopsPlay() async throws {
        let fixture = try await ImportStudioFixture.make()
        let gate = Gate()
        let studio = try await fixture.open(step: ChunkSeam(at: [1: { gate.waitOnce() }]))
        await studio.perform(.seek(.start))
        await studio.perform(.playStop)
        _ = await studio.renderOffline(frames: 4_800)
        let values = ProgressValues()

        let importing = Task { try await studio.importAudio(fixture.source, to: newTrack) { values.list.append($0) } }
        await gate.entered()

        #expect(studio.importRun?.name == "Voice.wav" && studio.playback == .stopped, "play stops at the start")
        #expect(throws: StudioError.busy, "an edit is busy") { try studio.edit { _ throws(SessionError) in } }
        await #expect(throws: StudioError.busy, "Cmd-L is busy") { try await studio.level(["c1"], .eachClip) }
        await #expect(throws: StudioError.busy, "a second import is busy") {
            try await studio.importAudio(fixture.source, to: newTrack) { _ in }
        }
        await #expect(throws: StudioError.busy, "a take is busy") { try await studio.startRecording(armed: ["t1"]) }
        gate.open()
        _ = try await importing.value

        #expect(studio.transport == .idle && studio.session.files["Voice"] != nil, "the import goes on")
        await until(limit: .seconds(10), "the last progress is not 1") { values.list.last == 1 }
        #expect(zip(values.list, values.list.dropFirst()).allSatisfy { $0 <= $1 }, "progress never goes down")
    }

    @Test func aCancelOfTheTaskChangesNothing() async throws {
        let fixture = try await ImportStudioFixture.make()
        let gate = Gate()
        let seam = ChunkSeam(at: [2: { gate.waitOnce() }])
        let studio = try await fixture.open(step: seam)
        let before = (fixture.xml, studio.session)

        let importing = Task { try await studio.importAudio(fixture.source, to: newTrack) { _ in } }
        await gate.entered()
        importing.cancel()
        gate.open()

        await #expect(throws: StudioError.audioImport(.cancelled)) { try await importing.value }
        #expect(seam.calls <= 3, "the import ends within one block: \(seam.calls) steps")
        #expect(fixture.xml == before.0 && studio.session == before.1 && !studio.canUndo, "nothing changed")
        #expect(fixture.clipsNames == ["f1.wav"] && studio.transport == .idle)
    }

    /// C5 f: a write can fail after `session.xml` was replaced, so the WAV stays as an unused file.
    @Test func aWriteFaultKeepsTheWAVAsAnUnusedFile() async throws {
        let fixture = try await ImportStudioFixture.make()
        let studio = try await fixture.open()
        let before = (fixture.xml, studio.session)
        studio.environment.saveSession = { _, _ throws(SessionFileError) in
            throw .writeFailed(step: "test", errno: EIO)
        }

        await #expect(throws: StudioError.file(.writeFailed(step: "test", errno: EIO))) {
            try await studio.importAudio(fixture.source, to: newTrack) { _ in }
        }

        #expect(studio.session == before.1 && !studio.canUndo, "the session in memory does not change")
        #expect(fixture.xml == before.0, "session.xml keeps its bytes")
        #expect(fixture.clipsNames == ["Voice.wav", "f1.wav"], "the WAV stays as an unused file")
        #expect(studio.transport == .idle)
    }

    @Test func aFailedImportLeavesTheTransportIdle() async throws {
        let fixture = try await ImportStudioFixture.make()
        let studio = try await fixture.open()
        let text = fixture.package.folder.url.appending(path: "notes.mp3")
        try Data("hello".utf8).write(to: text)

        await #expect(throws: StudioError.audioImport(.notAudio(file: "notes.mp3"))) {
            try await studio.importAudio(text, to: newTrack) { _ in }
        }
        #expect(studio.transport == .idle, "the transport is idle after a failed import")
    }

    @Test func thePeaksOfTheImportedFileLoad() async throws {
        let fixture = try await ImportStudioFixture.make()
        let cache = try TemporaryFolder()
        let studio = try await fixture.open(peakCache: cache.url)
        _ = await waitForPeaks(studio)

        _ = try await studio.importAudio(fixture.source, to: newTrack) { _ in }

        #expect(await waitForPeaks(studio, "Voice") != nil, "the peaks of the new file load")
        try studio.undo()
        try studio.redo()
        #expect(await waitForPeaks(studio, "Voice") != nil)
    }

    @Test func aCloseDuringAnImportEndsWithinOneBlock() async throws {
        let fixture = try await ImportStudioFixture.make()
        let gate = Gate()
        let seam = ChunkSeam(at: [2: { gate.waitOnce() }])
        let studio = try await fixture.open(step: seam)
        let before = (fixture.xml, studio.session)
        let importing = Task { try await studio.importAudio(fixture.source, to: newTrack) { _ in } }
        await gate.entered()

        let settle = Task { await studio.settle() }
        await until(limit: .seconds(10), "settle did not start") { studio.importRun?.flags.isCancelled == true }
        gate.open()
        await settle.value

        await #expect(throws: StudioError.audioImport(.cancelled)) { try await importing.value }
        #expect(seam.calls <= 3, "the import ends within one block: \(seam.calls) steps")
        #expect(fixture.xml == before.0 && studio.session == before.1 && fixture.clipsNames == ["f1.wav"])
    }

    @Test func anImportDuringSettleIsBusy() async throws {
        let fixture = try await ImportStudioFixture.make()
        let studio = try await fixture.open()
        let hold = AsyncGate()
        studio.environment.saveSession = { session, lock throws(SessionFileError) in
            await hold.wait()
            return try await CaptureEnvironment.live.saveSession(session, lock)
        }
        try studio.edit { session throws(SessionError) in try session.renameTrack("t1", to: "Host") }
        await hold.entered()
        let settle = Task { await studio.settle() }
        await until(limit: .seconds(10), "settle did not start") { studio.settling }

        let attempt = Task { try await studio.importAudio(fixture.source, to: newTrack) { _ in } }
        hold.open()

        await #expect(throws: StudioError.busy, "an import during settle is busy") { try await attempt.value }
        await settle.value
        #expect(fixture.clipsNames == ["f1.wav"])
    }

    /// As an export: the finalize of a pending take writes `Clips/` too.
    @Test func anImportDuringAPendingTakeIsBusy() async throws {
        let package = try TakePackage()
        FileManager.default.createFile(atPath: package.url.appending(path: "recovery-attempt").path, contents: nil)
        let fixture = try await ImportStudioFixture.make()
        let studio = try await Studio.open(package.url)
        #expect(studio.pendingTake != nil)

        await #expect(throws: StudioError.busy, "an import during a pending take is busy") {
            try await studio.importAudio(fixture.source, to: newTrack) { _ in }
        }
    }

    @Test(arguments: StudioExportTests.StartPath.allCases)
    func aTakeInAnotherStudioEndsTheImport(path: StudioExportTests.StartPath) async throws {
        let a = try await ExportStudioFixture.make()
        let hal = TestHAL([a.mic])
        let studioA = try await a.open(hal)
        let b = try await ImportStudioFixture.make()
        let studioB = try await b.open(step: ChunkSeam(pause: longChunk))
        let before = studioB.session
        let importing = Task { try await studioB.importAudio(b.source, to: newTrack) { _ in } }
        await until(limit: .seconds(30), "B did not start") { studioB.importRun != nil }
        studioA.otherStudios = { [studioB] }

        let host = try await StudioExportTests().start(path, studioA, a)

        await #expect(throws: StudioError.importYielded(file: "Voice.wav"), "B yields to the take") {
            try await importing.value
        }
        #expect(studioB.session == before && b.clipsNames == ["f1.wav"], "the import changed nothing")
        try await StudioExportTests().recordAndStop(studioA, hal, from: host)
    }

    /// The free space is low while B imports. The disk check of the take in A ends the import of
    /// B, and the take records on.
    @Test func theDiskCheckOfATakeEndsAnImportOnItsVolume() async throws {
        let a = try await ExportStudioFixture.make()
        let studioA = try await a.open(TestHAL([a.mic]))
        let b = try await ImportStudioFixture.make()
        let studioB = try await b.open(step: ChunkSeam(pause: longChunk))
        let clipsB = b.url.appending(path: clipsFolderName)
        studioA.environment.freeBytes = { _ in
            let temporary = (try? FileManager.default.contentsOfDirectory(atPath: clipsB.path))?
                .contains { $0.hasSuffix(".tmp") }
            return temporary == true ? 0 : 100_000_000_000
        }
        studioA.otherStudios = { [studioB] }
        try await studioA.startRecording(armed: ["t1"])

        let importing = Task { try await studioB.importAudio(b.source, to: newTrack) { _ in } }

        await #expect(throws: StudioError.importYielded(file: "Voice.wav"), "B yields to the disk check") {
            try await importing.value
        }
        try? await Task.sleep(for: .milliseconds(300))
        #expect(studioA.transport == .recording(take: 1), "the take records on")
        try await studioA.stopRecording()
    }
}
