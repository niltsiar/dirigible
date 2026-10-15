import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// A placement on a low or faulty disk, and a placement during a play (criteria 27 and 28).
extension PlaceSegmentTests {
    // MARK: Criteria 27 and 28

    /// The rule of a finalize for one segment: 3 WAV bytes for each 4 CAF bytes, plus 1 GB. Both
    /// sides of the boundary.
    @Test @MainActor func aPlacementOnALowDiskIsRefused() async throws {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: package.capture.appending(path: "take1-1-1.caf").path)
        let caf = try #require((attributes[.size] as? NSNumber)?.int64Value)
        let free = FreeBytes(caf * 3 / 4 + diskMargin - 1)
        let studio = try await studio(free: free)
        let (session, clipFiles) = (studio.session, try clipBytes())

        await #expect(throws: StudioError.placementSpace(needed: caf * 3 / 4 + diskMargin, free: free.value)) {
            try await studio.place(Self.segment)
        }

        #expect(studio.session == session)
        #expect(try clipBytes() == clipFiles)
        #expect(studio.transport == .idle)

        free.value += 1
        _ = try await studio.place(Self.segment)
        #expect(studio.session.track("t1")?.clips.map { $0 } == [Self.recorded])
    }

    /// A folder at the WAV path makes the rename fail: the error is thrown, the session does not
    /// change, and no temporary WAV stays.
    @Test @MainActor func aWriteFaultLeavesNoPartialWAV() async throws {
        try FileManager.default.removeItem(at: clips.appending(path: "take1-1-1.wav"))
        try FileManager.default.createDirectory(
            at: clips.appending(path: "take1-1-1.wav"), withIntermediateDirectories: false)
        let studio = try await studio()
        let session = studio.session

        await #expect(throws: StudioError.finalize(.writeFailed(file: "Clips/take1-1-1.wav", status: EISDIR))) {
            try await studio.place(Self.segment)
        }

        #expect(studio.session == session)
        #expect(try temporaryFiles() == [])
        #expect(studio.unplacedSegments == [Self.segment])
    }

    /// A placement stops a play before its conversion, as a take start does, and a play after it
    /// hears the placed clip. The clip of `t2` moves after the placed clip, so only the placed
    /// clip can sound at its start.
    @Test @MainActor func aPlacementStopsThePlay() async throws {
        let studio = try await studio()
        try studio.edit(ripple: false) { session throws(SessionError) in
            try session.move("take1-2-1", to: "t2", start: 300_000)
        }
        await studio.perform(.seek(.frame(96_432)))
        await studio.perform(.playStop)
        let silence = await studio.renderOffline(frames: 4_800)
        #expect(silence.joined().allSatisfy { $0 == 0 }, "control: no clip sounds before the placement")
        #expect(studio.playback != .stopped)
        let gate = AsyncGate()
        studio.environment.beforeFinalize = { await gate.wait() }

        let placing = Task { try await studio.place(Self.segment) }
        await gate.entered()

        #expect(studio.playback == .stopped)
        gate.open()
        _ = try await placing.value

        await studio.perform(.seek(.frame(96_432)))
        await studio.perform(.playStop)
        let sound = await studio.renderOffline(frames: 4_800)
        #expect(sound.joined().contains { abs($0) > 0.1 }, "the placed clip sounds")
        await studio.perform(.playStop)
    }
}
