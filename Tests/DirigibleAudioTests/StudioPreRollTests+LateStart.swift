import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The late start of a pre-roll take (decision 0070, criterion P17): the first frame of `mic`, less
/// its input latency of 0, against H_T + 3 IO buffers of 512 frames (32 ms at 48 kHz).
extension StudioPreRollTests {
    /// A take at T = 2 s (with 1 s of pre-roll, or none) whose input starts `offset` nanoseconds
    /// after H_T, then a stop. The stop drops the records after its host time, and H_T of a
    /// Command-R take is the host clock at the save, so the stop waits for that clock to pass the
    /// last record.
    func takeWithInput(from offset: Int64, preRoll: Int? = 1) async throws -> Studio {
        let studio = try await studio()
        try await studio.startRecording(armed: ["t1"], playhead: 96_000, preRoll: preRoll)
        let saved = try #require(studio.session.recording?.takeStartHostTimeNanos)
        await input(from: offset, seconds: 0.5)
        let end = saved + UInt64(offset) + 500_000_000
        await until(limit: .seconds(2), "the host clock passes the last record") { hostNanosNow() > end }
        try await studio.stopRecording()
        return studio
    }

    /// 200 ms after H_T + 3 IO buffers.
    @Test func lateFirstFrameReportsAGap() async throws {
        let studio = try await takeWithInput(from: 232_000_000)

        #expect(studio.lastTake?.lateStarts == ["t1"])
        #expect(studio.lastTake?.gaps == [:])
    }

    /// Control: 1 IO buffer after H_T is within the limit.
    @Test func lateFirstFrameWithinToleranceHasNoGap() async throws {
        let studio = try await takeWithInput(from: 10_666_667)

        #expect(studio.lastTake?.lateStarts == [])
    }

    /// A Command-R take never checks it, also with the first frame 200 ms after the limit.
    @Test func plainTakeHasNoLateStart() async throws {
        let studio = try await takeWithInput(from: 232_000_000, preRoll: nil)

        #expect(studio.lastTake?.lateStarts == [])
        #expect(takeClip(studio)?.start == Frames(96_000 + 11_136), "the take recorded")
    }
}
