import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// `Studio.importSession` (decision 0075, C12): one undo step that keeps the copied WAVs, the
/// busy refusal under a pending take, and the yield to a take in another studio.
@MainActor
struct StudioSessionImportTests {
    let target: MixPackage
    let source: MixPackage

    init() throws {
        target = try MixPackage(name: "Host")
        try target.addFile("take1-mic", channels: [sine(seconds: 1, rate: 48_000)])
        try target.addTrack("t1", clip: "A", file: "take1-mic", start: 0, offset: 0, length: 48_000)
        try target.session.write(to: target.url)
        source = try SessionImportTests.package("Guest")
        try source.addFile("take1-mic", channels: [sine(seconds: 2, rate: 48_000)])
        try source.addTrack("g1", clip: "G", file: "take1-mic", start: 24_000, offset: 0, length: 48_000)
        try source.session.write(to: source.url)
    }

    func open(step: ChunkSeam = ChunkSeam()) async throws -> Studio {
        let studio = try await Studio.open(target.url)
        studio.environment = .test(TestHAL([]))
        studio.environment.importStep = { step.step() }
        return studio
    }

    func names() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: target.url.appending(path: clipsFolderName).path)) ?? [])
            .sorted()
    }

    /// The import is one undo entry named for the Undo title; Undo removes the track and keeps
    /// the WAV, and Redo copies nothing.
    @Test func aSessionImportIsOneUndoStep() async throws {
        let studio = try await open()

        let imported = try await studio.importSession(source.url, markers: false) { _ in }

        let track = try #require(imported.tracks.first)
        #expect(studio.session.tracks.map(\.name) == ["t1", "g1"] && studio.session.tracks.last?.id == track)
        #expect(studio.session.track(track)?.clips.map(\.start) == [24_000])
        let saved = try Session(contentsOf: target.url)
        #expect(saved == studio.session, "session.xml has the import")
        #expect(names() == ["take1-mic 2.wav", "take1-mic.wav"], "\(names())")
        #expect(studio.undoName == .importSession && studio.undoAgent == nil)
        try studio.undo()
        #expect(studio.session.tracks.count == 1 && !studio.canUndo, "one undo step removes the new track")
        #expect(studio.redoName == .importSession && studio.undoName == nil)
        #expect(names() == ["take1-mic 2.wav", "take1-mic.wav"], "the WAV stays after Undo")
        try studio.redo()
        #expect(studio.session == saved, "Redo brings the import back")
        #expect(names() == ["take1-mic 2.wav", "take1-mic.wav"], "Redo copies nothing")
        try studio.edit(ripple: false) { session throws(SessionError) in try session.renameTrack("t1", to: "Host") }
        #expect(studio.undoName == nil, "a later edit has the plain title")
        await studio.settle()
    }

    /// An import under a pending take is busy and changes nothing.
    @Test func aSessionImportIsBusyDuringAPendingTake() async throws {
        let package = try TakePackage()
        FileManager.default.createFile(atPath: package.url.appending(path: "recovery-attempt").path, contents: nil)
        let studio = try await Studio.open(package.url)
        try #require(studio.pendingTake != nil)
        let before = studio.session

        await #expect(throws: StudioError.busy) {
            try await studio.importSession(source.url, markers: false) { _ in }
        }
        #expect(studio.session == before && !studio.canUndo)
    }

    /// A take in another studio ends a running import with the yield, not with a Cancel: the
    /// session, session.xml, and the target Clips/ listing are as before.
    @Test func aTakeInAnotherStudioEndsTheImport() async throws {
        let hold = Gate(limit: nil)
        defer { hold.open() }
        let studio = try await open()
        studio.environment.importStep = { hold.waitOnce() }
        let xml = FileManager.default.contents(atPath: target.url.appending(path: "session.xml").path)
        let before = (studio.session, names())
        let importing = Task { try await studio.importSession(source.url, markers: false) { _ in } }
        await hold.entered()
        #expect(studio.importRun?.kind == .session && studio.importRun?.name == "Guest", "the banner names the source")

        let a = try await ExportStudioFixture.make()
        let hal = TestHAL([a.mic])
        let studioA = try await a.open(hal)
        studioA.otherStudios = { [studio] }
        let start = Task { try await studioA.startTake(armed: ["t1"], devices: [a.mic], hostTimeNanos: takeStart) }
        await until(limit: .seconds(10), "the take did not start") { studioA.transport == .recording(take: 1) }
        hold.open()

        await #expect(throws: StudioError.sessionImportYielded(source: "Guest")) { try await importing.value }
        #expect(studio.session == before.0 && names() == before.1 && !studio.canUndo)
        #expect(FileManager.default.contents(atPath: target.url.appending(path: "session.xml").path) == xml)
        _ = try await start.value
        try await StudioExportTests().recordAndStop(studioA, hal, from: takeStart)
    }
}
