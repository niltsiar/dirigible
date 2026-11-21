import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleCore

/// Criteria C3, C4, C6, C7, and C10 of decision 0076: `Studio.syncClip` on the package of
/// `syncPackage`, where clip "C" at 35 s has its audio 5 s earlier on track "ref".
@MainActor
struct StudioSyncTests {
    static let agent = AgentName(title: "Test Agent", clientName: nil)

    static func studio(
        start: Frames = 1_680_000, reference: [Float]? = nil, edit: (MixPackage) throws -> Void = { _ in }
    ) async throws -> (MixPackage, Studio) {
        let package = try await Self.package(start: start, reference: reference)
        try edit(package)
        try package.session.write(to: package.url)
        return (package, try await Studio.open(package.url))
    }

    /// `syncPackage` off the main actor.
    @concurrent nonisolated static func package(start: Frames, reference: [Float]?) async throws -> sending MixPackage {
        try syncPackage(start: start, reference: reference)
    }

    /// 100 s of speech that is not the speech of `syncPackage`, made off the main actor.
    @concurrent nonisolated static func unrelatedSpeech() async -> [Float] {
        SpeechLike(seconds: 100, rate: 48_000, seed: 7).frames(0..<4_800_000)
    }

    static func sessionBytes(_ package: MixPackage) throws -> Data {
        try Data(contentsOf: package.url.appending(path: "session.xml"))
    }

    /// The clip moves by the lag, keeps its ID, offset, length, and gain, and cuts the clip under
    /// its new range on its track; the other track does not change. One undo entry with the agent
    /// gives the session before.
    @Test func aMatchMovesTheClipInOneUndoStep() async throws {
        let (package, studio) = try await Self.studio { package in
            try package.session.place(Clip(id: "K", file: "c", start: 960_000, offset: 0, length: 576_000), on: "c")
            try package.session.setGain(Gain(dB: -3)!, clip: "C")
        }
        let before = studio.session

        let (result, cut) = try await studio.syncClip("C", to: "ref", agent: Self.agent)

        #expect(result.lag == -240_000 && cut == SyncCut(head: .zero, replaced: ["K"]), "\(cut)")
        let moved = try #require(studio.session.clip("C")?.clip)
        #expect(moved.start == 1_440_000, "start \(moved.start)")
        #expect(moved.offset == .zero && moved.length == 1_440_000 && moved.gain == Gain(dB: -3)!)
        #expect(studio.session.clip("K")?.clip.range == 960_000..<1_440_000, "the clip under the new range is cut")
        #expect(studio.session.track("ref") == before.track("ref"))
        #expect(try Session(contentsOf: package.url) == studio.session, "the sync did not save")
        #expect(studio.undoAgent == Self.agent)
        try studio.undo()
        #expect(studio.session == before && !studio.canUndo, "the sync is more than one undo step")
    }

    @Test func noMatchChangesNothing() async throws {
        let unrelated = await Self.unrelatedSpeech()
        let (package, studio) = try await Self.studio(reference: unrelated)
        let bytes = try Self.sessionBytes(package)
        await #expect {
            try await studio.syncClip("C", to: "ref")
        } throws: { error in
            guard case StudioError.syncNoMatch(let best) = error else { return false }
            return !best.isMatch
        }
        #expect(try Self.sessionBytes(package) == bytes && !studio.canUndo && studio.transport == .idle)
    }

    /// Each refusal has its own error and changes nothing: the track of the clip, an unknown clip,
    /// an unknown track, a track with no clip in the span, a missing reference file, and a busy
    /// studio.
    @Test func eachRefusalChangesNothing() async throws {
        let (package, studio) = try await Self.studio { package in
            try package.session.addTrack("e", name: "e", layout: .mono)
        }
        let bytes = try Self.sessionBytes(package)
        let refusals: [(ClipID, TrackID, StudioError)] = [
            ("C", "c", .session(.syncSameTrack)), ("Q", "ref", .session(.unknownClip("Q"))),
            ("C", "Q", .session(.unknownTrack("Q"))), ("C", "e", .session(.noReferenceAudio)),
        ]
        for (clip, track, error) in refusals {
            await #expect(throws: error) { try await studio.syncClip(clip, to: track) }
        }
        let gate = AsyncGate()
        studio.environment.beforeFinalize = { await gate.wait() }
        let first = Task { try await studio.syncClip("C", to: "ref") }
        await gate.entered()
        await #expect(throws: StudioError.busy) { try await studio.syncClip("C", to: "ref") }
        studio.cancelReadJob()
        gate.open()
        _ = await first.result
        studio.environment.beforeFinalize = {}
        try FileManager.default.removeItem(at: package.url.appending(path: "\(clipsFolderName)/r.wav"))
        await #expect(throws: StudioError.syncFile("r", .missing)) { try await studio.syncClip("C", to: "ref") }
        #expect(try Self.sessionBytes(package) == bytes && !studio.canUndo && studio.transport == .idle)
    }

    /// A reference file cut short after the matching passage reads the frames that exist.
    @Test func aShortReferenceFileStillSyncs() async throws {
        let (package, studio) = try await Self.studio()
        let file = package.url.appending(path: "\(clipsFolderName)/r.wav")
        let size = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? UInt64)
        let frames = try package.truncate("r", toBytes: size - 30 * 48_000 * 3)
        #expect(frames >= 3_360_000 && frames < 4_800_000, "\(frames) frames")
        let (result, _) = try await studio.syncClip("C", to: "ref")
        #expect(result.lag == -240_000)
    }

    /// A true lag of -90 s is not found with `within` 60 s and is found with 120 s.
    @Test func theSearchStaysInsideWithin() async throws {
        let (package, studio) = try await Self.studio(start: 5_760_000)
        let bytes = try Self.sessionBytes(package)
        await #expect {
            try await studio.syncClip("C", to: "ref", within: 2_880_000)
        } throws: { error in
            guard case StudioError.syncNoMatch = error else { return false }
            return true
        }
        #expect(try Self.sessionBytes(package) == bytes)
        let (result, _) = try await studio.syncClip("C", to: "ref", within: 5_760_000)
        #expect(result.lag == -4_320_000)
    }

    @Test func aCancelSavesNothing() async throws {
        let (package, studio) = try await Self.studio()
        let bytes = try Self.sessionBytes(package)
        let before = studio.session
        let gate = AsyncGate()
        studio.environment.beforeFinalize = { await gate.wait() }
        let syncing = Task { try await studio.syncClip("C", to: "ref") }
        await gate.entered()
        #expect(studio.transport == .syncing, "sync hold: \(studio.transport)")
        studio.cancelReadJob()
        gate.open()
        let result = await syncing.result
        #expect(throws: StudioError.syncCancelled) { try result.get() }
        #expect(studio.session == before && !studio.canUndo && studio.transport == .idle)
        #expect(try Self.sessionBytes(package) == bytes, "a cancelled sync saved")
    }

    /// While the read runs, a move of the clip, an undo, a redo, and a revert each throw `.busy`;
    /// then the clip moves by the lag from its start place.
    @Test func noEditChangesTheClipDuringASync() async throws {
        let (package, studio) = try await Self.studio()
        for name in ["one", "two"] {
            try studio.edit(ripple: false) { session throws(SessionError) in try session.renameTrack("c", to: name) }
        }
        try studio.undo()
        #expect(studio.canUndo && studio.canRedo)
        let gate = AsyncGate()
        studio.environment.beforeFinalize = { await gate.wait() }
        let syncing = Task { try await studio.syncClip("C", to: "ref") }
        await gate.entered()

        #expect(throws: StudioError.busy) {
            try studio.edit(ripple: false) { session throws(SessionError) in try session.nudge(["C"], by: 48_000) }
        }
        #expect(throws: StudioError.busy) { try studio.undo() }
        #expect(throws: StudioError.busy) { try studio.redo() }
        await #expect(throws: StudioError.busy) { try await studio.revert(to: Backup(saved: Date())) }
        gate.open()

        _ = try await syncing.value
        #expect(studio.session.clip("C")?.clip.start == 1_440_000)
        #expect(studio.session.track("c")?.name == "one")
        #expect(try Session(contentsOf: package.url) == studio.session, "the sync did not save")
    }
}
