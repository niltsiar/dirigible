import DirigibleCore
import Testing

@testable import DirigibleAudio

/// The seek and shuttle rules of the agent transport calls (C5b, C7). The fixture is in
/// `StudioPlayRangeTests`.
extension StudioPlayRangeTests {
    /// The agent locate and a user seek during a forward play: N = E - 1 plays on; N = E and
    /// N = E + 4800 stop the play at N, which is also the Stop and Return point.
    @Test(arguments: [false, true], [95_999, 96_000, 100_800])
    func aSeekPastTheEndDuringAPlayStopsThere(agent: Bool, target: Int) async throws {
        let studio = try await studio()
        await studio.perform(.seek(.frame(24_000)))
        await studio.perform(.playStop)
        _ = await studio.renderOffline(frames: 4800)
        let n = Frames(target)
        let stops = target >= 96_000

        if agent {
            let outcome = try await studio.locate(n)
            let state: TransportState = stops ? .stopped(at: n) : .playing(from: n, to: 96_000, shuttle: forward)
            #expect(outcome == .state(state))
        } else {
            await studio.perform(.seek(.frame(n)))
        }

        #expect(studio.playback == (stops ? .stopped : .playing(forward)))
        await studio.perform(.stopAndReturn)
        #expect(studio.playhead == n, "the Stop and Return point")
    }

    /// J from 48 000, then a locate to 30 000: the play goes on in reverse from there.
    @Test func aLocateDuringAReversePlayKeepsIt() async throws {
        let studio = try await studio()
        let reverse = Shuttle(direction: .reverse, rate: .one)
        await studio.perform(.seek(.frame(48_000)))
        await studio.perform(.reverse)
        _ = await studio.renderOffline(frames: 4800)

        let outcome = try await studio.locate(30_000)

        #expect(outcome == .state(.playing(from: 30_000, to: 0, shuttle: reverse)))
        #expect(studio.playback == .playing(reverse))
        let out = await studio.renderOffline(frames: 4800)
        expectMix(out, try package.mix(25_200..<30_000).map { Array($0.reversed()) }, "reverse from 30 000")
        await studio.perform(.pause)
    }

    /// Reverse 1x and forward 2x: an agent play starts one forward 1x play with its end.
    @Test(arguments: [[TransportCommand.reverse], [.forward, .forward]])
    func aPlayDuringAShuttleStartsForward(keys: [TransportCommand]) async throws {
        let studio = try await studio()
        await studio.perform(.seek(.frame(48_000)))
        for key in keys { await studio.perform(key) }
        _ = await studio.renderOffline(frames: 4800)

        let outcome = try await studio.play(from: 30_000, to: 40_000)

        #expect(outcome == .state(.playing(from: 30_000, to: 40_000, shuttle: forward)))
        #expect(studio.playback == .playing(forward))
        let out = await studio.renderOffline(frames: 3 * 4800)
        expectMix(slice(out, 0..<10_000), try package.mix(30_000..<40_000), "forward 1x from 30 000")
        expectSilence(slice(out, 10_000..<14_400), "no mix after the end")
        await studio.perform(.pause)
    }
}
