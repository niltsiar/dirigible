import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Two saved packages for `Studio.paste` (decision 0042). P: track t1 with clip A of take1-mic
/// (1 s of tone). Q: tracks u1 and u2, and its own take1-mic (silence) with clip Z on u2.
struct PasteStudioFixture {
    let p: MixPackage
    let q: MixPackage

    @concurrent nonisolated static func make() async throws -> sending PasteStudioFixture {
        let p = try MixPackage()
        try p.addFile("take1-mic", channels: [sine(seconds: 2, rate: 48_000)])
        try p.addTrack("t1", clip: "A", file: "take1-mic", start: 0, offset: 0, length: 48_000)
        try p.session.write(to: p.url)
        let q = try MixPackage()
        try q.addFile("take1-mic", channels: [[Float](repeating: 0, count: 48_000)])
        try q.session.addTrack("u1", name: "u1", layout: .mono)
        try q.addTrack("u2", clip: "Z", file: "take1-mic", start: 0, offset: 0, length: 48_000)
        try q.session.write(to: q.url)
        return PasteStudioFixture(p: p, q: q)
    }

    @MainActor func open(_ package: MixPackage, step: ChunkSeam = ChunkSeam()) async throws -> Studio {
        let studio = try await Studio.open(package.url)
        studio.environment = .test(TestHAL([]))
        studio.environment.importStep = { step.step() }
        return studio
    }

    func names(_ package: MixPackage) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: package.url.appending(path: clipsFolderName).path)) ?? [])
            .sorted()
    }

    func xml(_ package: MixPackage) -> Data? {
        FileManager.default.contents(atPath: package.url.appending(path: "session.xml").path)
    }
}

/// `Studio.paste` (decision 0042): one undo entry, the WAV after Undo, cancel, the yield to a take,
/// a pending take, Insert, a moved source, and a conversion.
@MainActor
struct StudioPasteTests {
    /// C9 at the studio: Undo removes the clip and the record and keeps the WAV; Redo copies nothing.
    @Test func aPasteIsOneUndoEntryAndKeepsTheFileAfterUndo() async throws {
        let fixture = try await PasteStudioFixture.make()
        let (p, q) = (try await fixture.open(fixture.p), try await fixture.open(fixture.q))
        let clipboard = p.clipboard(of: try p.session.excerpt(of: 0..<48_000, on: ["t1"]))

        let (clips, tracks) = try await q.pasteAcross(clipboard, from: p, at: 96_000, on: .tracks(["u1"])) { _ in }

        #expect(clips == ["A@96000"] && tracks == ["u1"])
        let saved = try Session(contentsOf: fixture.q.url)
        #expect(saved == q.session && saved.clip("A@96000")?.clip.file == "take1-mic 2", "session.xml has the paste")
        #expect(fixture.names(fixture.q) == ["take1-mic 2.wav", "take1-mic.wav"])
        try q.undo()
        #expect(q.session.files["take1-mic 2"] == nil && q.session.clip("A@96000") == nil && !q.canUndo)
        #expect(fixture.names(fixture.q) == ["take1-mic 2.wav", "take1-mic.wav"], "the WAV stays after Undo")
        try q.redo()
        #expect(q.session == saved, "Redo brings the paste back with no copy")
        #expect(fixture.names(fixture.q) == ["take1-mic 2.wav", "take1-mic.wav"])
    }

    /// C8 at the studio: a cancel of the task, then a take in another studio (the yield).
    @Test func aCancelOrATakeInAnotherStudioStopsAPaste() async throws {
        let fixture = try await PasteStudioFixture.make()
        let gate = Gate(limit: Gate.openLimit)
        let p = try await fixture.open(fixture.p)
        let q = try await fixture.open(fixture.q, step: ChunkSeam(at: [1: { gate.waitOnce() }]))
        let clipboard = p.clipboard(of: try p.session.excerpt(of: 0..<48_000, on: ["t1"]))
        let before = (fixture.xml(fixture.q), q.session)

        let pasting = Task { try await q.pasteAcross(clipboard, from: p, at: 0, on: .tracks(["u1"])) { _ in } }
        await gate.entered()
        #expect(q.importRun?.kind == .paste && q.importRun?.name == "Mix", "the banner run names the source")
        pasting.cancel()
        gate.open()

        await #expect(throws: StudioError.paste(.cancelled, source: "Mix")) { try await pasting.value }
        #expect(fixture.xml(fixture.q) == before.0 && q.session == before.1 && !q.canUndo)
        #expect(fixture.names(fixture.q) == ["take1-mic.wav"] && q.transport == .idle)

        let a = try await ExportStudioFixture.make()
        let hal = TestHAL([a.mic])
        let studioA = try await a.open(hal)
        let hold = Gate(limit: nil)
        q.environment.importStep = { hold.waitOnce() }
        defer { hold.open() }
        let second = Task { try await q.pasteAcross(clipboard, from: p, at: 0, on: .tracks(["u1"])) { _ in } }
        await hold.entered()
        studioA.otherStudios = { [q] }
        let start = Task { try await studioA.startTake(armed: ["t1"], devices: [a.mic], hostTimeNanos: takeStart) }
        await until(limit: .seconds(10), "the take did not start") { studioA.transport == .recording(take: 1) }
        hold.open()

        await #expect(throws: StudioError.pasteYielded(source: "Mix")) { try await second.value }
        #expect(fixture.names(fixture.q) == ["take1-mic.wav"], "the yielded paste leaves no file")
        _ = try await start.value
        try await StudioExportTests().recordAndStop(studioA, hal, from: takeStart)
    }

    /// C14: a cross paste during a pending take is busy, as an import.
    @Test func aCrossPasteIsBusyDuringAPendingTake() async throws {
        let fixture = try await PasteStudioFixture.make()
        let package = try TakePackage()
        FileManager.default.createFile(atPath: package.url.appending(path: "recovery-attempt").path, contents: nil)
        let p = try await fixture.open(fixture.p)
        let studio = try await Studio.open(package.url)
        #expect(studio.pendingTake != nil)
        let clipboard = p.clipboard(of: try p.session.excerpt(of: 0..<48_000, on: ["t1"]))

        await #expect(throws: StudioError.busy) {
            try await studio.pasteAcross(clipboard, from: p, at: 0, on: .tracks(["t1"])) { _ in }
        }
    }

    /// C13 at the studio: Insert moves all tracks right and pastes, in one undo entry; also with
    /// new tracks for no selected track.
    @Test func insertMovesAllTracksAndPastes() async throws {
        let fixture = try await PasteStudioFixture.make()
        let p = try await fixture.open(fixture.p)
        let q = try await fixture.open(fixture.q)
        let clipboard = p.clipboard(of: try p.session.excerpt(of: 0..<48_000, on: ["t1"]))

        let (clips, _) = try await q.pasteAcross(clipboard, from: p, at: 0, on: .unselected, insert: true) { _ in }

        #expect(q.session.clip("Z")?.clip.start == 48_000, "Z moves right by the excerpt length")
        #expect(
            q.session.tracks.map(\.name) == ["u1", "u2", "t1"]
                && q.session.clip(clips[0])?.track == q.session.tracks[2].id)
        try q.undo()
        #expect(q.session.tracks.count == 2 && q.session.clip("Z")?.clip.start == 0 && !q.canUndo)
    }

    /// C5a: the open source studio resolves its package after a rename with no save; a lock that
    /// throws `.packageMoved` refuses with the source name.
    @Test func aMovedSourceResolvesThroughItsOpenStudio() async throws {
        let fixture = try await PasteStudioFixture.make()
        let p = try await fixture.open(fixture.p)
        let q = try await fixture.open(fixture.q)
        let clipboard = p.clipboard(of: try p.session.excerpt(of: 0..<48_000, on: ["t1"]))
        let moved = fixture.p.folder.url.appending(path: "Moved.dirigible")
        try #require(rename(fixture.p.url.path, moved.path) == 0)

        _ = try await q.pasteAcross(clipboard, from: p, at: 0, on: .tracks(["u1"])) { _ in }
        #expect(q.session.files["take1-mic 2"] != nil, "the paste found the moved package")
        await #expect(throws: StudioError.paste(.sourceMissing(file: "Mix.dirigible"), source: "Mix")) {
            try await q.pasteAcross(clipboard, from: nil, at: 0, on: .tracks(["u1"])) { _ in }
        }
        try FileManager.default.removeItem(at: moved)
        await #expect(throws: StudioError.paste(.sourceMissing(file: "Mix.dirigible"), source: "Mix")) {
            try await q.pasteAcross(clipboard, from: p, at: 0, on: .tracks(["u1"])) { _ in }
        }
    }

    /// C18d: `.unselected` in the same package uses the source tracks.
    @Test func theUnselectedTargetOfTheSamePackageUsesTheSourceTracks() async throws {
        let fixture = try await PasteStudioFixture.make()
        let q = try await fixture.open(fixture.q)
        let clipboard = q.clipboard(of: try q.session.excerpt(of: 0..<48_000, on: ["u2"]))

        let (clips, tracks) = try #require(try q.pasteInPlace(clipboard, at: 96_000, on: .unselected))

        #expect(clips == ["Z@96000"] && tracks == ["u2"] && fixture.names(fixture.q) == ["take1-mic.wav"])
    }
}
