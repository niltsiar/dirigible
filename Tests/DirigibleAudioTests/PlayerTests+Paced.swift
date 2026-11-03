import AVFoundation
import DirigibleCore
import Foundation
import Testing
import os

@testable import DirigibleAudio

/// A clock that only the test moves: the paced Player pulls no frame until the test advances it.
final class FrozenClock: @unchecked Sendable {
    private let lock = NSLock()
    private let start = ContinuousClock.now
    private var offset = Duration.zero

    var now: ContinuousClock.Instant { lock.withLock { start + offset } }
    func advance(_ by: Duration) { lock.withLock { offset += by } }
}

extension Player {
    /// True when the engine renders manually, so it binds no output device.
    var rendersManually: Bool { graph?.engine.isInManualRenderingMode == true }
}

/// The paced output of the Player (decision 0016, amended): the engine renders offline, and the
/// tick pulls frames at the pace of the host clock, as a device output does.
extension PlayerTests {
    /// A package with a track of `seconds` of ramp.
    func longPackage(seconds: Int) throws -> MixPackage {
        let frames = seconds * 48_000
        let long = try MixPackage()
        try long.addFile("f1", channels: [ramp(frames: frames)])
        try long.addTrack("t1", clip: "c1", file: "f1", start: 0, offset: 0, length: Frames(frames))
        return long
    }

    /// A paced Player over `long`.
    func pacedPlayer(_ long: MixPackage, now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) -> Player {
        let url = long.url
        return Player(package: { url }, output: .paced, session: long.session, now: now)
    }

    /// Polls `condition` each 5 ms. False after the hang guard of 10 s. It checks once more after
    /// the guard, so a stall of the test task past the guard does not fail a condition that holds.
    func within10Seconds(_ condition: () async -> Bool) async -> Bool {
        let end = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < end {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    @Test func pacedPlayMovesWithNoPull() async throws {
        let long = try longPackage(seconds: 10)
        defer { withExtendedLifetime(long) {} }
        let player = pacedPlayer(long)
        await player.apply(.play(from: 0, shuttle: forward), number: 1)
        let moved = await within10Seconds { await player.reading().frame >= 14_400 }
        #expect(moved, "the position reached 0.3 s with no pull of the test")
    }

    @Test func pacedPlayFollowsTheHostClock() async throws {
        let long = try longPackage(seconds: 10)
        defer { withExtendedLifetime(long) {} }
        let player = pacedPlayer(long)
        let start = ContinuousClock.now
        await player.apply(.play(from: 0, shuttle: forward), number: 1)
        #expect(await within10Seconds { await player.reading().frame > 0 }, "the play moved")
        try await Task.sleep(for: .milliseconds(500))
        let frame = await player.reading().frame.count
        let elapsed = (ContinuousClock.now - start) / .seconds(1)
        #expect(frame <= Int(elapsed * 48_000) + 4800, "frame \(frame) after \(elapsed) s")
    }

    @Test func aClockJumpRendersAtMostOneSecond() async throws {
        let long = try longPackage(seconds: 30)
        defer { withExtendedLifetime(long) {} }
        let clock = FrozenClock()
        let player = pacedPlayer(long, now: { clock.now })
        await player.apply(.play(from: 0, shuttle: forward), number: 1)
        func settle() async -> Bool {
            let ticks = await player.ticks
            return await within10Seconds { await player.ticks >= ticks + 2 }
        }
        #expect(await settle(), "the ticks ran")
        #expect(await player.reading().frame == 0, "a frozen clock pulls nothing")

        clock.advance(.seconds(10))
        #expect(await settle(), "the ticks ran after the jump")
        let jumped = await player.reading().frame.count
        #expect((48_000...52_800).contains(jumped), "the jump of 10 s moved the position to \(jumped)")

        clock.advance(.milliseconds(500))
        #expect(await settle(), "the ticks ran after the half second")
        let later = await player.reading().frame.count
        #expect((72_000 - 4800...72_000 + 4800).contains(later), "the playhead paused over the gap: \(later)")
    }

    @Test func pacedPlayEnds() async throws {
        let short = try MixPackage()
        try short.addFile("f1", channels: [ramp(frames: 24_000)])
        try short.addTrack("t1", clip: "c1", file: "f1", start: 0, offset: 0, length: 24_000)
        let player = pacedPlayer(short)
        await player.apply(.play(from: 0, shuttle: forward), number: 1)
        #expect(await within10Seconds { await player.reading().ended }, "the play of 0.5 s ended")
    }

    @Test func pacedPlayOpensNoDevice() async throws {
        let long = try longPackage(seconds: 1)
        defer { withExtendedLifetime(long) {} }
        let player = pacedPlayer(long)
        await player.apply(.play(from: 0, shuttle: forward), number: 1)
        #expect(await player.rendersManually)
    }

    @Test func pacedPlayFeedsTheMeter() async throws {
        let long = try longPackage(seconds: 10)
        defer { withExtendedLifetime(long) {} }
        let player = pacedPlayer(long)
        await player.apply(.play(from: 0, shuttle: forward), number: 1)
        #expect(await within10Seconds { await player.reading().loudness.seconds > 0 }, "the meter measured")
    }

    @Test func aFailedPacedRenderEndsThePlay() async throws {
        let long = try longPackage(seconds: 10)
        defer { withExtendedLifetime(long) {} }
        let url = long.url
        let player = Player(
            package: { url }, output: .paced, session: long.session, pacedRender: { _, _, _ in .error })
        await player.apply(.play(from: 0, shuttle: forward), number: 1)
        let stopped = await within10Seconds { await player.reading().stop != nil }
        #expect(stopped, "the failed render ended the play")
        let code = AVAudioEngineManualRenderingStatus.error.rawValue
        #expect(await player.reading().stop == .outputUnavailable(code))
    }

    @Test func aRefillStopEndsThePacedPull() async throws {
        let long = try longPackage(seconds: 30)
        defer { withExtendedLifetime(long) {} }
        let url = long.url
        let gone = OSAllocatedUnfairLock(initialState: false)
        let clock = FrozenClock()
        let player = Player(
            package: {
                if gone.withLock({ $0 }) { throw CocoaError(.fileNoSuchFile) }
                return url
            }, output: .paced, session: long.session, now: { clock.now })
        await player.apply(.play(from: 0, shuttle: forward), number: 1)
        gone.withLock { $0 = true }
        clock.advance(.seconds(1))
        let stopped = await within10Seconds { await player.reading().stop == .packageUnavailable }
        #expect(stopped, "the refill found no package")
        let pulled = await player.pacedPulled
        let chunk = long.session.sampleRate / 10
        #expect(pulled <= 2 * chunk, "the pull rendered \(pulled) frames, more than two chunks")
    }
}
