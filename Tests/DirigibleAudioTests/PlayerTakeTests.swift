import AVFoundation
import DirigibleCore
import Foundation
import Testing
import os

@testable import DirigibleAudio

extension Player {
    /// The first frame of the running feed.
    var feedAnchor: Frames? { feed?.anchor }
}

/// A host clock that the test sets: each read gives the time, then moves it by the next step. The
/// last step repeats.
final class HostClock: Sendable {
    private let state: OSAllocatedUnfairLock<(now: UInt64, steps: [UInt64])>

    init(_ now: UInt64) { state = OSAllocatedUnfairLock(initialState: (now, [0])) }

    func set(_ now: UInt64, steps: [UInt64] = [0]) { state.withLock { $0 = (now, steps) } }

    func read() -> UInt64 {
        state.withLock { clock in
            defer {
                clock.now += clock.steps[0]
                if clock.steps.count > 1 { clock.steps.removeFirst() }
            }
            return clock.now
        }
    }
}

/// Criteria P18, P28, and P32 (run 2026-10-28-pre-roll): a take play starts through `apply` at a
/// host time that keeps the lead, `Reading` gives that start and the output term, and an underrun
/// of a take feed keeps the map from host time to frame.
struct PlayerTakeTests {
    let package: MixPackage
    let forward = Shuttle(direction: .forward, rate: .one)
    /// A host time far from 0, so no sum wraps.
    let h0: UInt64 = 1_000_000_000_000
    /// The host times that the start-time seam got, nil for a start at once.
    let starts = OSAllocatedUnfairLock<[UInt64?]>(initialState: [])

    /// A mono track with one clip of 96000 distinct frames at timeline 0, at 48 kHz.
    init() throws {
        package = try MixPackage()
        try package.addFile("f1", channels: [ramp(frames: 100_000)])
        try package.addTrack("t1", clip: "c1", file: "f1", start: 0, offset: 0, length: 96_000)
    }

    /// A Player whose host clock is `host`, or the real one when nil.
    func player(
        output: Player.Output = .offline, host: HostClock? = nil,
        start: @escaping @Sendable (AVAudioEngine) throws -> Void = { try $0.start() },
        open: @escaping MediaOpen = openMedia, readTerm: OutputTermRead? = nil,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) -> Player {
        let (url, starts) = (package.url, starts)
        return Player(
            package: { url }, output: output, session: package.session, start: start, open: open, speedUnit: { nil },
            readTerm: readTerm, now: now, hostNanos: { host?.read() ?? hostNanosNow() },
            startNode: { node, at in
                starts.withLock { $0.append(at) }
                node.play()
            })
    }

    func take(floor: UInt64, span: Frames) -> Player.Command {
        .play(from: 2400, shuttle: forward, take: Player.TakeStart(floor: floor, span: span))
    }

    /// An older command does nothing to a take play, and a newer one stops it.
    @Test func takePlayHasAFeedNumber() async throws {
        let player = player(host: HostClock(h0))
        await player.apply(take(floor: h0 + 2_000_000_000, span: 24_000), number: 2)
        await player.apply(.stop, number: 1)
        var reading = await player.reading()
        #expect(reading.played == 2 && reading.running)
        #expect(reading.realStart == h0 + 2_000_000_000)
        await player.apply(.stop, number: 3)
        reading = await player.reading()
        #expect(reading.number == 3 && !reading.running && reading.realStart == nil)
    }

    /// With the seam term 19 + 284 + 77 + 512 at 48 kHz, `Reading` has the start host time that
    /// the start-time seam got, and that term: 18,583,333 ns.
    @Test func readingHasTheStartAndTheTerm() async throws {
        let player = player(host: HostClock(h0), readTerm: { _ in .success(.builtIn) })
        await player.apply(take(floor: h0 + 2_000_000_000, span: 24_000), number: 1)
        let reading = await player.reading()
        #expect(starts.withLock { $0 } == [h0 + 2_000_000_000])
        #expect(reading.realStart == h0 + 2_000_000_000)
        #expect(reading.term == .builtIn && reading.term.nanos(sessionRate: 48_000) == 18_583_333)
    }

    /// The engine start takes 300 ms, and T - S is 0.2 s: H_T is still 0.5 s or more after the
    /// engine start returns. A lead of 0.4 s gives less.
    @Test func slowEngineStartKeepsTheLead() async throws {
        let returned = OSAllocatedUnfairLock<UInt64>(initialState: 0)
        let player = player(start: { engine in
            Thread.sleep(forTimeInterval: 0.3)
            try engine.start()
            returned.withLock { $0 = hostNanosNow() }
        })
        await player.apply(take(floor: hostNanosNow() + 100_000_000, span: 9600), number: 1)
        let start = try #require(await player.reading().realStart)
        let anchor = takeStartHostNanos(realStart: start, term: .manual(0), from: 2400, to: 12_000, rate: 48_000)
        let lead = Int64(anchor) - Int64(returned.withLock { $0 })
        #expect(lead >= 500_000_000, "lead \(lead) ns")
    }

    /// The open of the first refill takes 150 ms: the start host time is 100 ms or more after it.
    @Test func slowFirstRefillKeepsTheStartAhead() async throws {
        let opened = OSAllocatedUnfairLock<UInt64>(initialState: 0)
        let player = player(open: { file, clips, rate throws(POSIXError) in
            Thread.sleep(forTimeInterval: 0.15)
            defer { opened.withLock { $0 = hostNanosNow() } }
            return try openMedia(file, in: clips, rate: rate)
        })
        await player.apply(take(floor: hostNanosNow() + 100_000_000, span: 96_000), number: 1)
        let start = try #require(await player.reading().realStart)
        let ahead = Int64(start) - Int64(opened.withLock { $0 })
        #expect(ahead >= 100_000_000, "the start is \(ahead) ns after the open")
    }

    /// The host clock at H0 and the clock of the pull at X: a start host time of H0 + 300 ms
    /// gives a paced base of X + 300 ms, not X.
    @Test func pacedBaseIsTheStartHostTime() async throws {
        let clock = FrozenClock()
        let x = clock.now
        let player = player(output: .paced, host: HostClock(h0), now: { clock.now })
        await player.apply(take(floor: h0 + 300_000_000, span: 96_000), number: 1)
        #expect(await player.pacedBase == x + .milliseconds(300))
    }

    /// The paced pull owes no frame before the start host time, and 0.1 s of frames 100 ms after it.
    @Test func pacedTakePlayPullsFromTheStart() async throws {
        let clock = FrozenClock()
        let player = player(output: .paced, host: HostClock(h0), now: { clock.now })
        await player.apply(take(floor: h0 + 300_000_000, span: 96_000), number: 1)
        func settle() async -> Bool {
            let ticks = await player.ticks
            let end = ContinuousClock.now + .seconds(10)
            while ContinuousClock.now < end, await player.ticks < ticks + 2 {
                try? await Task.sleep(for: .milliseconds(5))
            }
            return await player.ticks >= ticks + 2
        }
        clock.advance(.milliseconds(200))
        #expect(await settle(), "the ticks ran")
        #expect(await player.pacedPulled == 0, "no frame before the start")
        clock.advance(.milliseconds(200))
        #expect(await settle(), "the ticks ran after the start")
        #expect(await player.pacedPulled == 4800)
    }

    /// Negative control of P28: an underrun of a plain play restarts at once at the frame after the
    /// last scheduled frame, with no start host time.
    @Test func underrunInAPlainPlayRestartsAtOnce() async throws {
        let player = player(host: HostClock(h0))
        await player.apply(.play(from: 2400, shuttle: forward), number: 1)
        _ = await player.renderOffline(frames: 4 * 4800, starve: true)
        await player.refill()
        #expect(await player.feedAnchor == 16_800)
        #expect(starts.withLock { $0 }.isEmpty, "a plain play starts with no seam call")
        let out = await player.renderOffline(frames: 4800)
        #expect(maxError(out[0], try package.mix(16_800..<21_600)[0]) <= 1e-6)
    }

    /// An `.offline` Player with no start seam ignores the host time (U20), so an underrun of its
    /// take feed restarts at once at the frame after the last scheduled frame, as a plain play does.
    @Test func underrunOfAnOfflineTakeRestartsAtOnce() async throws {
        let clock = HostClock(h0)
        let url = package.url
        let player = Player(
            package: { url }, output: .offline, session: package.session, speedUnit: { nil },
            hostNanos: { clock.read() })
        await player.apply(take(floor: h0 + 100_000_000, span: 96_000), number: 1)
        clock.set(h0 + 1_000_000_000)
        _ = await player.renderOffline(frames: 4 * 4800, starve: true)
        await player.refill()
        #expect(await player.feedAnchor == 16_800)
    }

    /// A take started at H0 + 0.1 s from frame 2400 runs dry, and the refill reads H0 + 1 s: the
    /// restart starts at H0 + 1.1 s, at the frame due then, 2400 + 1.0 s x 48 kHz. A second
    /// underrun at H0 + 1.5 s counts from the take start too: 74400, not 50400 + 1.5 s x 48 kHz.
    @Test func underrunKeepsTheHostMap() async throws {
        let clock = HostClock(h0)
        let player = player(host: clock)
        await player.apply(take(floor: h0 + 100_000_000, span: 96_000), number: 1)
        clock.set(h0 + 1_000_000_000)
        _ = await player.renderOffline(frames: 4 * 4800, starve: true)
        await player.refill()
        #expect(await player.feedAnchor == 50_400)
        #expect(starts.withLock { $0 } == [h0 + 100_000_000, h0 + 1_100_000_000])
        let out = await player.renderOffline(frames: 4800)
        #expect(maxError(out[0], try package.mix(50_400..<55_200)[0]) <= 1e-6, "the frames due at the restart")
    }

    @Test func secondUnderrunKeepsTheBase() async throws {
        let clock = HostClock(h0)
        let player = player(host: clock)
        await player.apply(take(floor: h0 + 100_000_000, span: 96_000), number: 1)
        for (now, anchor) in [(h0 + 1_000_000_000, Frames(50_400)), (h0 + 1_500_000_000, 74_400)] {
            clock.set(now)
            _ = await player.renderOffline(frames: 5 * 4800, starve: true)
            await player.refill()
            #expect(await player.feedAnchor == anchor)
            _ = await player.renderOffline(frames: 4800)
        }
        #expect(starts.withLock { $0 } == [h0 + 100_000_000, h0 + 1_100_000_000, h0 + 1_600_000_000])
    }

    /// The schedule of the restart takes 150 ms of the host clock, so the pick at H0 + 1.1 s is
    /// late. The next pick is 100 ms + 150 ms after the check at H0 + 1.15 s: H0 + 1.4 s, at frame
    /// 2400 + 1.3 s x 48 kHz.
    @Test func slowRestartRefillPicksAgain() async throws {
        let clock = HostClock(h0)
        let player = player(host: clock)
        await player.apply(take(floor: h0 + 100_000_000, span: 96_000), number: 1)
        clock.set(h0 + 1_000_000_000, steps: [150_000_000])
        _ = await player.renderOffline(frames: 4 * 4800, starve: true)
        await player.refill()
        #expect(await player.feedAnchor == 64_800)
        #expect(starts.withLock { $0 } == [h0 + 100_000_000, h0 + 1_400_000_000])
        let out = await player.renderOffline(frames: 4800)
        #expect(maxError(out[0], try package.mix(64_800..<69_600)[0]) <= 1e-6, "the frames of the second pick")
    }

    /// The restart schedule fails (no free descriptor for `f2` at 40000): the node still plays at
    /// once, as a plain refill does, so the next refill can restart it.
    @Test func failedRestartScheduleStartsTheNode() async throws {
        try package.addFile("f2", channels: [ramp(frames: 50_000, channel: 1)])
        try package.addTrack("t2", clip: "c2", file: "f2", start: 40_000, offset: 0, length: 50_000)
        let clock = HostClock(h0)
        let player = player(
            host: clock,
            open: { file, clips, rate throws(POSIXError) in
                if file.id == "f2" { throw POSIXError(.EMFILE) }
                return try openMedia(file, in: clips, rate: rate)
            })
        await player.apply(take(floor: h0 + 100_000_000, span: 96_000), number: 1)
        clock.set(h0 + 1_000_000_000)
        _ = await player.renderOffline(frames: 4 * 4800, starve: true)
        await player.refill()

        #expect(await player.reading().stop == .noFreeDescriptor(Int(EMFILE)))
        #expect(starts.withLock { $0 } == [h0 + 100_000_000, nil])
    }

    /// Each schedule takes longer than the last (0.2 s, 0.4 s, 0.8 s), so the picks at
    /// H0 + 0.6 s, 1.1 s, and 1.6 s are late. After the third, the node plays at once with the
    /// frames of the third pick: 2400 + 1.5 s x 48 kHz.
    @Test func thirdLatePickPlaysAtOnce() async throws {
        let clock = HostClock(h0)
        let player = player(host: clock)
        await player.apply(take(floor: h0 + 100_000_000, span: 96_000), number: 1)
        clock.set(h0 + 500_000_000, steps: [200_000_000, 400_000_000, 800_000_000])
        _ = await player.renderOffline(frames: 4 * 4800, starve: true)
        await player.refill()
        #expect(await player.feedAnchor == 74_400)
        #expect(starts.withLock { $0 } == [h0 + 100_000_000, nil])
    }
}
