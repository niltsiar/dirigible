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

/// Criteria P18 and P32 (run 2026-10-28-pre-roll): a take play starts through `apply` at a host
/// time that keeps the lead, and `Reading` gives that start and the output term.
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
        output: Player.Output = .offline, host: OSAllocatedUnfairLock<UInt64>? = nil,
        start: @escaping @Sendable (AVAudioEngine) throws -> Void = { try $0.start() },
        open: @escaping MediaOpen = openMedia, readTerm: OutputTermRead? = nil,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) -> Player {
        let (url, starts) = (package.url, starts)
        return Player(
            package: { url }, output: output, session: package.session, start: start, open: open, speedUnit: { nil },
            readTerm: readTerm, now: now, hostNanos: { host?.withLock { $0 } ?? hostNanosNow() },
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
        let player = player(host: OSAllocatedUnfairLock(initialState: h0))
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
        let player = player(host: OSAllocatedUnfairLock(initialState: h0), readTerm: { _ in .success(.builtIn) })
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
        let player = player(output: .paced, host: OSAllocatedUnfairLock(initialState: h0), now: { clock.now })
        await player.apply(take(floor: h0 + 300_000_000, span: 96_000), number: 1)
        #expect(await player.pacedBase == x + .milliseconds(300))
    }

    /// The paced pull owes no frame before the start host time, and 0.1 s of frames 100 ms after it.
    @Test func pacedTakePlayPullsFromTheStart() async throws {
        let clock = FrozenClock()
        let player = player(output: .paced, host: OSAllocatedUnfairLock(initialState: h0), now: { clock.now })
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
        let player = player(host: OSAllocatedUnfairLock(initialState: h0))
        await player.apply(.play(from: 2400, shuttle: forward), number: 1)
        _ = await player.renderOffline(frames: 4 * 4800, starve: true)
        await player.refill()
        #expect(await player.feedAnchor == 16_800)
        #expect(starts.withLock { $0 }.isEmpty, "a plain play starts with no seam call")
        let out = await player.renderOffline(frames: 4800)
        #expect(maxError(out[0], try package.mix(16_800..<21_600)[0]) <= 1e-6)
    }
}
