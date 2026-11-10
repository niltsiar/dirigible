import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The stop and Retry Finalize judge a writer by the time its queue ended the finish (decision
/// 0030), not by the order of the deadline and the answer.
extension StartLimitTests {
    enum Caller: CaseIterable, Sendable { case stop, retry }

    /// `mic` is lost and its come-back attach waits, so its gaps have `deviceLost`. The release of
    /// that attach lets the finish end. The deadline is past at the call of `caller`, so no wait
    /// runs: read before the release, `mic` is late; read after the finish returned, `mic` is on
    /// time with the gaps of its finish.
    @Test(arguments: Caller.allCases, [false, true])
    func aFinishThatEndedByTheDeadlineIsOnTimeWhenReadAfterIt(caller: Caller, late: Bool) async throws {
        let hal = hal()
        defer { hal.releaseAttach("mic") }
        let studio = try await studio(hal, stop: limit)
        try await studio.startRecording(armed: ["t1"], playhead: 0)
        let writer = try #require(studio.writer("mic"))
        try await holdComeBack(writer, hal, "mic")

        switch caller {
        case .stop:
            let before = ContinuousClock.now
            hal.releaseAttach("mic")
            await writer.finish()
            let deadline = late ? before : ContinuousClock.now
            let (gaps, unfinished) = await studio.finishWriters(by: deadline, abandoned: [])
            if late {
                #expect(unfinished.map(\.uid) == ["mic"], "late writers: \(unfinished.map(\.uid))")
                #expect(gaps["t1"] == nil, "\(gaps)")
            } else {
                #expect(unfinished.isEmpty, "late writers: \(unfinished.map(\.uid))")
                #expect(gaps == ["t1": .deviceLost], "\(gaps)")
            }
            try await studio.stopRecording()
        case .retry:
            await #expect(throws: StudioError.writerDidNotStop("USB Mic")) { try await studio.stopRecording() }
            let before = ContinuousClock.now
            hal.releaseAttach("mic")
            if !late { await writer.finish() }
            let deadline = late ? before : ContinuousClock.now
            let error = await studio.finishUnfinished(by: deadline)
            if late {
                #expect(error == .writerDidNotStop("USB Mic"), "\(String(describing: error))")
                #expect(studio.unfinishedWriters.map(\.uid) == ["mic"])
                #expect(studio.lastTake?.gaps["t1"] == nil)
            } else {
                #expect(error == nil, "\(String(describing: error))")
                #expect(studio.unfinishedWriters.isEmpty)
                #expect(studio.lastTake?.gaps["t1"] == .deviceLost)
            }
            try await studio.retryFinalize()
        }
        await studio.settle()
    }
}
