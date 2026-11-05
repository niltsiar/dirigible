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
    /// clock stands still before the stop records on after each wake of the stop wait, and stops
    /// after the clock reaches the stop.
    @Test func timedTakeOutlastsAHostClockThatStandsStill() async throws {
        let studio = try await studio()
        let clock = SleepingHostClock()
        studio.environment.hostNanos = { clock.read() }
        let (wait, waitReads) = (studio.environment.takeStop, OSAllocatedUnfairLock(initialState: 0))
        studio.environment.takeStop = { stop, read in
            await wait(stop) {
                waitReads.withLock { $0 += 1 }
                return read()
            }
        }
        let take = try await studio.startRecording(armed: ["t1"], playhead: 96_000, for: .milliseconds(500), preRoll: 1)
        let start = try #require(studio.session.recording?.takeStartHostTimeNanos)
        let stop = timedTakeStop(end: start + 500_000_000, devices: [Self.mic])

        await until(limit: .seconds(10), "the stop wait reads the clock after a sleep") {
            waitReads.withLock { $0 } >= 2
        }
        #expect(
            studio.transport == .recording(take: take),
            "the take stopped at the host clock \(clock.read()), before \(stop)")
        clock.go()
        await until(limit: .seconds(10), "the take stops") { studio.transport != .recording(take: take) }
        let end = clock.read()
        #expect(end >= start + 500_000_000, "the take ended \(Int64(bitPattern: end &- start)) ns after H_T")
        await until(limit: .seconds(10), "the take finalizes") { studio.transport == .idle }
    }
}

/// A host clock that stands still at its first read until `go()`, as in a system sleep, and then
/// reads the host clock. H_T is at least 100 ms after a read of the clock (the take start of the
/// Player), so the clock stands still before the stop of a take on every schedule.
private final class SleepingHostClock: Sendable {
    private struct State {
        var still: UInt64?
        var awake = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func read() -> UInt64 {
        state.withLock { state in
            if state.awake { return hostNanosNow() }
            let still = state.still ?? hostNanosNow()
            state.still = still
            return still
        }
    }

    func go() { state.withLock { $0.awake = true } }
}
