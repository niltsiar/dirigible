import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// A main-actor hold between the stop call and the end of the start step does not make a healthy
/// writer late (decision 0030): its finish starts at the stop call on its own queue.
extension StartLimitTests {
    /// The fields of each `take writer-finished` line of `USB Mic` in the journal of `log`.
    func micFinishedLines(_ log: DiagnosticLog, in logs: URL) -> [[String: String]] {
        TakeLogTests.lines(log, in: logs).filter { $0.contains("\ttake\twriter-finished\t") }
            .map { fieldValues($0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)) }
            .filter { $0["writer"] == "USB Mic" }
    }

    /// A Stop while the first attach of `box` waits, then a main-actor job that the stop task
    /// queued first holds the main actor past the stop deadline, before the start step unwinds.
    /// The finish of the healthy `mic` ends during the hold, so `mic` is on time and the take
    /// finalizes. With `late`, the come-back attach of `mic` waits until a job that the hold
    /// queues at its end, so `mic` answers after the deadline.
    @Test(arguments: [false, true])
    func aMainActorHoldDuringTheStartUnwindKeepsTheHealthyWriterOnTime(late: Bool) async throws {
        let stopLimit = Duration.milliseconds(250)
        let hold = Duration.milliseconds(900)
        let hal = hal()
        hal.holdAttach("box")
        defer {
            hal.releaseAttach("box")
            hal.releaseAttach("mic")
        }
        let logs = folder.url.appending(path: "logs")
        let log = startLog(in: logs)
        let studio = try await studio(hal, stop: stopLimit)
        studio.environment.log = log
        let mics = play(hal, "mic")
        let started = Task { try await studio.startRecording(armed: ["t1", "t2"], playhead: 0) }
        await until(limit: busy, "the take did not begin") { studio.transport == .recording(take: 1) }
        await until(limit: busy, "mic did not attach") { hal.current("mic") != nil }
        try await Task.sleep(for: .milliseconds(300))
        if late { try await holdComeBack(studio.writer("mic"), hal, "mic") }

        let stopping = Task { @MainActor () -> StudioError? in
            do throws(StudioError) { try await studio.stopRecording() } catch { return error }
            return nil
        }
        let held = Task { @MainActor in
            usleep(UInt32(hold / .microseconds(1)))
            return Task { @MainActor in hal.releaseAttach("mic") }
        }
        let error = await stopping.value
        await held.value.value
        let unfinished = studio.unfinishedWriters.map(\.uid)
        try await started.value
        await mics.wait()

        if late {
            #expect(error == .writerDidNotStop("USB Mic"), "\(String(describing: error))")
            #expect(unfinished == ["mic"], "late writers: \(unfinished)")
            try await studio.retryFinalize()
        } else {
            #expect(error == nil, "\(String(describing: error))")
            #expect(studio.lastTake?.gaps["t2"] == .deviceLost)
            #expect(clipFrames(studio, "t1").reduce(0, +) > 0, "no frames of t1")
            #expect(unfinished.isEmpty, "late writers: \(unfinished)")
            let finished = micFinishedLines(log, in: logs)
            let limit = Double(stopLimit / .milliseconds(1))
            #expect(
                finished.count == 1 && finished.allSatisfy { (Double($0["ms"] ?? "") ?? .infinity) <= limit },
                "\(finished)")
        }
        await studio.settle()
    }
}
