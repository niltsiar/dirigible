import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Two saved packages for `Studio.pasteAcross` and `Studio.pasteInPlace` (decision 0042). P: track t1 with clip A of take1-mic
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

    /// A package with clip A (1 s of tone) on t1 and a pending take 2, open in a studio.
    @MainActor func pendingTake() async throws -> (studio: Studio, package: MixPackage) {
        let package = try MixPackage()
        try package.addFile("take1-mic", channels: [sine(seconds: 2, rate: 48_000)])
        try package.addTrack("t1", clip: "A", file: "take1-mic", start: 0, offset: 0, length: 48_000)
        try package.session.setRecording(
            Recording(take: 2, playheadFrame: 96_000, takeStartHostTimeNanos: takeStart, armedTracks: ["t1"]))
        try package.session.write(to: package.url)
        try FileManager.default.createDirectory(
            at: package.url.appending(path: "Capture"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: package.url.appending(path: "recovery-attempt").path, contents: nil)
        let studio = try await open(package)
        try #require(studio.pendingTake != nil)
        return (studio, package)
    }
}

/// `Studio.pasteAcross` and `Studio.pasteInPlace` (decision 0042): one undo entry, the WAV after Undo, cancel, the yield to a take,
/// a pending take, Insert, a moved source, and a conversion.
@MainActor
struct StudioPasteTests {
    /// C9 at the studio: Undo removes the clip and the record and keeps the WAV; Redo copies nothing.
    @Test func aPasteIsOneUndoEntryAndKeepsTheFileAfterUndo() async throws {
        let fixture = try await PasteStudioFixture.make()
        let (p, q) = (try await fixture.open(fixture.p), try await fixture.open(fixture.q))
        let clipboard = p.clipboard(of: try p.session.excerpt(of: 0..<48_000, on: ["t1"]))

        let (clips, tracks) = try await q.pasteAcross(clipboard, from: p, mode: .over(at: 96_000), on: .tracks(["u1"]))
        { _ in }

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

        let pasting = Task {
            try await q.pasteAcross(clipboard, from: p, mode: .over(at: 0), on: .tracks(["u1"])) { _ in }
        }
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
        let second = Task {
            try await q.pasteAcross(clipboard, from: p, mode: .over(at: 0), on: .tracks(["u1"])) { _ in }
        }
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
            try await studio.pasteAcross(clipboard, from: p, mode: .over(at: 0), on: .tracks(["t1"])) { _ in }
        }
    }

    /// Decision 0037: an Insert under a pending take is a ripple refusal; a paste across stays
    /// busy. Controls m5, m6, and m7.
    @Test func anInsertUnderAPendingTakeIsARippleRefusal() async throws {
        let fixture = try await PasteStudioFixture.make()
        let package = try TakePackage()
        FileManager.default.createFile(atPath: package.url.appending(path: "recovery-attempt").path, contents: nil)
        let p = try await fixture.open(fixture.p)
        let studio = try await Studio.open(package.url)
        try #require(studio.pendingTake != nil)
        let clipboard = p.clipboard(of: try p.session.excerpt(of: 0..<48_000, on: ["t1"]))
        var refusals: [StudioError?] = [nil, nil, nil]

        do throws(StudioError) {
            _ = try await studio.pasteAcross(clipboard, from: p, mode: .insert(at: 0), on: .tracks(["t1"])) { _ in }
        } catch { refusals[0] = error }
        do throws(StudioError) {
            _ = try await studio.pasteAcross(clipboard, from: p, mode: .over(at: 0), on: .tracks(["t1"])) { _ in }
        } catch { refusals[1] = error }
        let own = studio.clipboard(of: try studio.session.excerpt(of: 0..<48_000, on: ["t1"]))
        do throws(StudioError) {
            _ = try studio.pasteInPlace(own, mode: .insert(at: 0), on: .tracks(["t1"]))
        } catch { refusals[2] = error }

        #expect(refusals[0] == .rippleBlocked, "RIPPLE-S3 an Insert across under a pending take is no ripple refusal")
        #expect(refusals[1] == .busy, "RIPPLE-S4 a paste across under a pending take is not busy")
        #expect(refusals[2] == .rippleBlocked, "RIPPLE-S7 an Insert in place under a pending take is no ripple refusal")
    }

    /// C12: a Replace in one package under a pending take is a ripple refusal that changes
    /// nothing; on an idle studio the same Replace moves the later audio on every track.
    @Test func replaceRippleBlocked() async throws {
        let fixture = try await PasteStudioFixture.make()
        let q = try await fixture.open(fixture.q)
        let ownQ = q.clipboard(of: try q.session.excerpt(of: 0..<48_000, on: ["u2"]))
        _ = try #require(try q.pasteInPlace(ownQ, mode: .replace(0..<24_000), on: .tracks(["u1"])))
        #expect(q.session.track("u1")?.clips.map(\.start) == [0], "the clipboard is at the range start")
        #expect(q.session.track("u2")?.clips.map(\.start) == [48_000], "the tail of Z moves by 48 000 - 24 000")
        let (studio, package) = try await fixture.pendingTake()
        let own = studio.clipboard(of: try studio.session.excerpt(of: 0..<48_000, on: ["t1"]))
        let before = (studio.session, fixture.xml(package))

        #expect(throws: StudioError.rippleBlocked) {
            try studio.pasteInPlace(own, mode: .replace(0..<24_000), on: .tracks(["t1"]))
        }

        #expect(studio.session == before.0 && fixture.xml(package) == before.1 && !studio.canUndo)
        #expect(studio.pendingTake != nil, "the take stays pending")
    }

    /// C12: a Replace from another package under a pending take is a ripple refusal, not busy,
    /// and copies no file; on an idle studio the same Replace copies and moves the later audio.
    @Test func replaceAcrossRippleBlocked() async throws {
        let fixture = try await PasteStudioFixture.make()
        let (p, q) = (try await fixture.open(fixture.p), try await fixture.open(fixture.q))
        let clipboard = p.clipboard(of: try p.session.excerpt(of: 0..<48_000, on: ["t1"]))
        let (clips, _) = try await q.pasteAcross(clipboard, from: p, mode: .replace(0..<24_000), on: .tracks(["u1"])) {
            _ in
        }
        #expect(clips == ["A@0"] && q.session.track("u2")?.clips.map(\.start) == [48_000])
        let (studio, package) = try await fixture.pendingTake()
        let before = (studio.session, fixture.xml(package), fixture.names(package))

        await #expect(throws: StudioError.rippleBlocked) {
            try await studio.pasteAcross(clipboard, from: p, mode: .replace(0..<24_000), on: .tracks(["t1"])) { _ in }
        }

        #expect(studio.session == before.0 && fixture.xml(package) == before.1 && !studio.canUndo)
        #expect(fixture.names(package) == before.2 && before.2 == ["take1-mic.wav"], "no file copied")
        #expect(studio.pendingTake != nil, "the take stays pending")
    }

    /// C12: a fill moves no audio, so it runs under a pending take, and the take stays pending.
    @Test func fillUnderPendingTake() async throws {
        let fixture = try await PasteStudioFixture.make()
        let (studio, _) = try await fixture.pendingTake()
        let own = studio.clipboard(of: try studio.session.excerpt(of: 0..<12_000, on: ["t1"]))

        let (clips, _) = try #require(try studio.pasteInPlace(own, mode: .fill(48_000..<96_000), on: .tracks(["t1"])))

        #expect(clips.count == 4 && studio.canUndo)
        #expect(studio.session.track("t1")?.clips.map(\.start) == [0, 48_000, 60_000, 72_000, 84_000])
        #expect(studio.pendingTake != nil, "the take stays pending")
    }

    /// C13 at the studio: Insert moves all tracks right and pastes, in one undo entry; also with
    /// new tracks for no selected track.
    @Test func insertMovesAllTracksAndPastes() async throws {
        let fixture = try await PasteStudioFixture.make()
        let p = try await fixture.open(fixture.p)
        let q = try await fixture.open(fixture.q)
        let clipboard = p.clipboard(of: try p.session.excerpt(of: 0..<48_000, on: ["t1"]))

        let (clips, _) = try await q.pasteAcross(clipboard, from: p, mode: .insert(at: 0), on: .unselected) { _ in }

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

        _ = try await q.pasteAcross(clipboard, from: p, mode: .over(at: 0), on: .tracks(["u1"])) { _ in }
        #expect(q.session.files["take1-mic 2"] != nil, "the paste found the moved package")
        await #expect(throws: StudioError.paste(.sourceMissing(file: "Mix.dirigible"), source: "Mix")) {
            try await q.pasteAcross(clipboard, from: nil, mode: .over(at: 0), on: .tracks(["u1"])) { _ in }
        }
        try FileManager.default.removeItem(at: moved)
        await #expect(throws: StudioError.paste(.sourceMissing(file: "Mix.dirigible"), source: "Mix")) {
            try await q.pasteAcross(clipboard, from: p, mode: .over(at: 0), on: .tracks(["u1"])) { _ in }
        }
    }

    /// C18d: `.unselected` in the same package uses the source tracks.
    @Test func theUnselectedTargetOfTheSamePackageUsesTheSourceTracks() async throws {
        let fixture = try await PasteStudioFixture.make()
        let q = try await fixture.open(fixture.q)
        let clipboard = q.clipboard(of: try q.session.excerpt(of: 0..<48_000, on: ["u2"]))

        let (clips, tracks) = try #require(try q.pasteInPlace(clipboard, mode: .over(at: 96_000), on: .unselected))

        #expect(clips == ["Z@96000"] && tracks == ["u2"] && fixture.names(fixture.q) == ["take1-mic.wav"])
    }
}
