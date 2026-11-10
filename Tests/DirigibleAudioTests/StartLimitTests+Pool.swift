import DirigibleCore
import Foundation
import Testing
import os

@testable import DirigibleAudio

/// Holds the threads of the concurrency pool: each of `jobs` tasks blocks one thread on a
/// semaphore until `release`.
private final class PoolHold: Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let unsignaled: OSAllocatedUnfairLock<Int>
    private let jobs: Int

    init(jobs: Int) {
        self.jobs = jobs
        unsignaled = OSAllocatedUnfairLock(initialState: jobs)
    }

    func fill() -> [Task<Void, Never>] { (0..<jobs).map { _ in Task { @concurrent in self.block() } } }

    private func block() { semaphore.wait() }

    /// Signals each job that no call signaled yet, so a second call does nothing.
    func release() {
        let count = unsignaled.withLock { count in
            defer { count = 0 }
            return count
        }
        for _ in 0..<count { semaphore.signal() }
    }
}

/// A full concurrency pool at the stop does not make a healthy writer late (decision 0030): its
/// finish starts at the stop call on its own queue, which is not a pool thread.
extension StartLimitTests {
    /// A Stop while the first attach of `box` waits, then a main-actor job that the stop task
    /// queued first fills every pool thread for longer than the stop limit. A `Thread` releases
    /// the pool. The finish of the healthy `mic` ends during the hold, so `mic` is on time and the
    /// take finalizes. With `late`, the come-back attach of `mic` waits until that thread releases
    /// it after the pool, so `mic` answers after the deadline. Slow: it holds the pool of the
    /// whole test process.
    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"), arguments: [false, true])
    func aFullPoolAtTheStopKeepsTheHealthyWriterOnTime(late: Bool) async throws {
        let stopLimit = Duration.milliseconds(250)
        let hold = Duration.milliseconds(1_500)
        let hal = hal()
        hal.holdAttach("box")
        let pool = PoolHold(jobs: 2 * ProcessInfo.processInfo.activeProcessorCount)
        defer {
            pool.release()
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

        let sentinelRan = OSAllocatedUnfairLock(initialState: false)
        let ranBeforeRelease = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        let stopping = Task { @MainActor () -> StudioError? in
            do throws(StudioError) { try await studio.stopRecording() } catch { return error }
            return nil
        }
        let filled = Task { @MainActor in
            let jobs = pool.fill()
            let sentinel = Task { @concurrent in sentinelRan.withLock { $0 = true } }
            Thread.detachNewThread {
                Thread.sleep(forTimeInterval: hold / .seconds(1))
                ranBeforeRelease.withLock { $0 = sentinelRan.withLock { $0 } }
                pool.release()
                if late { hal.releaseAttach("mic") }
            }
            return (jobs, sentinel)
        }
        // Nothing that needs a pool thread until the fill jobs end.
        let error = await stopping.value
        let (jobs, sentinel) = await filled.value
        for job in jobs { await job.value }
        await sentinel.value
        let unfinished = studio.unfinishedWriters.map(\.uid)
        try await started.value
        await mics.wait()

        #expect(ranBeforeRelease.withLock { $0 } == false, "the pool was not full")
        if late {
            #expect(error == .writerDidNotStop("USB Mic"), "\(String(describing: error))")
            #expect(unfinished == ["mic"], "late writers: \(unfinished)")
            studio.environment.stopLimit = busy
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
