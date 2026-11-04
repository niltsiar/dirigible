import DirigibleCore
import Foundation
import Testing
import os

@testable import DirigibleAudio

/// The timed pre-roll take of `dirigible record` and the `record` tool (decision 0070, criterion
/// P14), on the host clock.
extension StudioPreRollTests {
    /// A take of 2 s at T = 2 s. The input runs from H_T - 0.5 s for 3 s, and `mic` delivers each
    /// record 100 ms after its host time, 150 ms under the stop margin. The clip is the 2 s from T,
    /// so the stop waits for H_T, not for 2 s from the start return, and for the frames in flight.
    @Test(arguments: [1, 2])
    func recordForCountsFromT(preRoll: Int) async throws {
        let studio = try await studio()
        studio.environment.hostNanos = hostNanosNow
        let input = SyntheticInput(hal, "mic")
        input.play(
            records(
                [sine(seconds: 3, rate: 48_000)], layout: [1], rate: 48_000, frames: 480,
                hostStart: takeStart - 500_000_000),
            pace: .lagging(nanos: 100_000_000), takeStartIn: package.url)

        let result = try await studio.record(armed: ["t1"], playhead: 96_000, for: .seconds(2), preRoll: preRoll)
        await input.wait()

        #expect(result.end == .requested && result.gaps == [:])
        let clip = try #require(takeClip(studio))
        #expect(clip.start == 96_000 && clip.offset == 24_000 && clip.length == 96_000, "\(clip)")
    }

    /// A timed pre-roll take on a host clock in another base than `hostNanosNow`: the stop waits on
    /// that clock, so the take records its whole length after H_T.
    @Test func timedTakeWaitsOnTheTakeClock() async throws {
        let studio = try await studio()
        let shift = hostNanosNow() / 2
        studio.environment.hostNanos = { hostNanosNow() - shift }
        let take = try await studio.startRecording(armed: ["t1"], playhead: 96_000, for: .seconds(1), preRoll: 1)
        let start = try #require(studio.session.recording?.takeStartHostTimeNanos)

        await until(limit: .seconds(10), "the take stops") { studio.transport != .recording(take: take) }
        let end = studio.environment.hostNanos()
        #expect(end >= start + 1_000_000_000, "the take ended \(Int64(bitPattern: end &- start)) ns after H_T")
        await until(limit: .seconds(10), "the take finalizes") { studio.transport == .idle }
    }

    /// A system sleep stops the host clock and not the sleep clock. A timed pre-roll take whose host
    /// clock stands still after H_T records on after the wake of a sleep to the stop, and stops after
    /// the clock reaches the stop.
    @Test func timedTakeOutlastsAHostClockThatStandsStill() async throws {
        let studio = try await studio()
        let clock = SleepingHostClock()
        studio.environment.hostNanos = { clock.read() }
        let take = try await studio.startRecording(armed: ["t1"], playhead: 96_000, for: .milliseconds(500), preRoll: 1)
        let start = try #require(studio.session.recording?.takeStartHostTimeNanos)
        let stop = timedTakeStop(end: start + 500_000_000, devices: [Self.mic])

        await until(limit: .seconds(10), "the host clock reaches H_T") { hostNanosNow() >= start }
        let still = clock.standStill(past: stop)
        await until(limit: .seconds(10), "the stop wait reads the clock after its sleep") { clock.lateReads > 0 }
        #expect(
            studio.transport == .recording(take: take), "the take stopped at the host clock \(still), before \(stop)")
        clock.go()
        await until(limit: .seconds(10), "the take stops") { studio.transport != .recording(take: take) }
        let end = clock.read()
        #expect(end >= start + 500_000_000, "the take ended \(Int64(bitPattern: end &- start)) ns after H_T")
        await until(limit: .seconds(10), "the take finalizes") { studio.transport == .idle }
    }
}

/// A host clock that stands still from `standStill(past:)` to `go()`, as in a system sleep. It
/// counts its reads after the real time at which a running clock reaches the stop.
private final class SleepingHostClock: Sendable {
    private struct State {
        var still: UInt64?
        var behind: UInt64 = 0
        var due: ContinuousClock.Instant?
        var lateReads = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    var lateReads: Int { state.withLock { $0.lateReads } }

    func read() -> UInt64 {
        state.withLock { state in
            guard let still = state.still else { return hostNanosNow() - state.behind }
            if let due = state.due, ContinuousClock.now >= due { state.lateReads += 1 }
            return still
        }
    }

    /// Stands still at the current host time, which is before `stop`, and returns it.
    func standStill(past stop: UInt64) -> UInt64 {
        state.withLock { state in
            let still = hostNanosNow() - state.behind
            state.still = still
            // 10 ms under the wake of a sleep to `stop` that started on the running clock.
            state.due = .now + .nanoseconds(stop - still) - .milliseconds(10)
            return still
        }
    }

    func go() {
        state.withLock { state in
            if let still = state.still { state.behind = hostNanosNow() - still }
            state.still = nil
        }
    }
}
