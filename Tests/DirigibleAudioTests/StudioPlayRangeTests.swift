import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The agent transport calls of the Studio (run agent-transport, criteria C4 to C11, C14, and
/// C18): a play with an end, a locate, and a stop. The Player renders offline
/// (`CaptureEnvironment.test`). Tolerance: ± 1e-6 per sample (no gain).
@MainActor
struct StudioPlayRangeTests {
    let package: MixPackage
    let mic = InputDevice(
        uid: "mic", name: "USB Mic", nominalRate: 48_000, availableRates: [48_000...48_000], channelsPerBuffer: [1],
        latency: 0)!
    let forward = Shuttle(direction: .forward, rate: .one)

    /// Track `t1` on `mic` channel 1, with clip `c1` of the constant 0.5 over frames 0 to 96 000.
    init() throws {
        package = try MixPackage()
        try package.addFile("f1", channels: [[Float](repeating: 0.5, count: 96_000)])
        try package.addTrack("t1", clip: "c1", file: "f1", start: 0, offset: 0, length: 96_000)
        try package.session.setRoute(Route.device(uid: "mic", channels: .mono(1)), track: "t1")
        try package.session.write(to: package.url)
    }

    func studio(_ hal: TestHAL? = nil) async throws -> Studio {
        let studio = try await Studio.open(package.url)
        studio.environment = .test(hal ?? TestHAL([mic]))
        return studio
    }

    func expectMix(_ out: [[Float]], _ mix: [[Float]], _ comment: Comment) {
        #expect(out.count == 2 && mix.count == 2, comment)
        for (a, b) in zip(out, mix) { #expect(maxError(a, b) <= 1e-6, comment) }
    }

    func expectSilence(_ out: [[Float]], _ comment: Comment) {
        #expect(out.allSatisfy { $0.allSatisfy { $0 == 0 } }, comment)
    }

    /// Waits until the poll sees the end of the play. A hang guard: 3 times the worst wait of
    /// `theEndOfTheMaterialStopsAtTheEnd`.
    func untilStopped(_ studio: Studio) async {
        await until(limit: .seconds(19), "the play did not end") { studio.playback == .stopped }
    }

    /// The frame of the Player. A frame after T shows that the play has no end.
    func playerFrame(_ studio: Studio) async throws -> Frames {
        try #require(await studio.play.player?.reading().frame)
    }

    // MARK: C4, C9

    /// The worked fixture of C4: F = 24 000, T = 50 000 (not on a chunk edge).
    @Test func aPlayWithAnEndStopsAtTheEnd() async throws {
        let studio = try await studio()

        let outcome = try await studio.play(from: 24_000, to: 50_000)

        #expect(outcome == .state(.playing(from: 24_000, to: 50_000, shuttle: forward)))
        #expect(studio.playback == .playing(forward))
        let out = await studio.renderOffline(frames: 6 * 4800)
        expectMix(slice(out, 0..<26_000), try package.mix(24_000..<50_000), "the mix of F to T")
        expectSilence(slice(out, 26_000..<28_800), "no mix after T")
        await untilStopped(studio)
        #expect(studio.playhead == 50_000)
    }

    /// C9: the feed counts source frames at any speed, so the end holds at 1.5x.
    @Test func aPlayAtASpeedStopsAtTheEnd() async throws {
        let studio = try await studio()
        await studio.changeSpeed(to: .x150)
        try #require(studio.speed == .x150, "the speed unit loads")

        let outcome = try await studio.play(from: 24_000, to: 50_000)

        #expect(outcome == .state(.playing(from: 24_000, to: 50_000, shuttle: forward)))
        _ = await studio.renderOffline(frames: 6 * 4800)
        await untilStopped(studio)
        #expect(studio.playhead == 50_000)
    }

    // MARK: C4c

    /// `from = E - 1` plays; `from = E` changes nothing.
    @Test(arguments: [95_999, 96_000])
    func aPlayFromTheEndPlaysNothing(from: Int) async throws {
        let studio = try await studio()
        await studio.perform(.seek(.frame(1000)))
        let feed = studio.play.feed

        let outcome = try await studio.play(from: Frames(from), to: nil)

        if from < 96_000 {
            #expect(outcome == .state(.playing(from: 95_999, to: 96_000, shuttle: forward)))
            #expect(studio.playback == .playing(forward))
            await studio.perform(.pause)
        } else {
            #expect(outcome == .pastEnd(start: 96_000, end: 96_000))
            #expect(studio.playback == .stopped && studio.playhead == 1000 && studio.play.feed == feed)
        }
    }

    /// Stopped at P: `to = P` changes nothing, `to = P + 1` plays. Playing with the polled
    /// playhead H: `to = H` changes nothing, and the play goes on with the same feed number.
    @Test(arguments: [false, true])
    func aToBeforeTheStartPlaysNothing(playing: Bool) async throws {
        let studio = try await studio()
        await studio.perform(.seek(.frame(30_000)))
        if playing {
            await studio.perform(.playStop)
            _ = await studio.renderOffline(frames: 4800)
            await until(limit: .seconds(19), "no poll after the render") { studio.playhead == 34_800 }
        }
        let (start, feed) = (studio.playhead, studio.play.feed)

        let outcome = try await studio.play(from: nil, to: start)

        #expect(outcome == .pastEnd(start: start, end: start))
        #expect(studio.play.feed == feed && studio.playhead == start)
        #expect(studio.playback == (playing ? .playing(forward) : .stopped))
        if !playing {
            let next = try await studio.play(from: nil, to: start + 1)
            #expect(next == .state(.playing(from: start, to: start + 1, shuttle: forward)))
        }
        await studio.perform(.pause)
    }

    // MARK: C8

    /// The agent locate and a user seek: a target before T keeps T; a target at or after T plays
    /// to the session end.
    @Test(arguments: [false, true], [40_000, 50_000, 60_000])
    func aSeekBeforeTheEndKeepsIt(agent: Bool, target: Int) async throws {
        let studio = try await studio()
        _ = try await studio.play(from: 24_000, to: 50_000)
        _ = await studio.renderOffline(frames: 4800)
        let end: Frames = target < 50_000 ? 50_000 : 96_000

        if agent {
            let outcome = try await studio.locate(Frames(target))
            #expect(outcome == .state(.playing(from: Frames(target), to: end, shuttle: forward)))
        } else {
            await studio.perform(.seek(.frame(Frames(target))))
        }

        let out = await studio.renderOffline(frames: 6 * 4800)
        let mixed = min(6 * 4800, (end - Frames(target)).count)
        expectMix(slice(out, 0..<mixed), try package.mix(Frames(target)..<Frames(target + mixed)), "the mix to the end")
        expectSilence(slice(out, mixed..<6 * 4800), "no mix after the end")
        if end == 50_000 {
            await untilStopped(studio)
            #expect(studio.playhead == 50_000)
        }
        await studio.perform(.pause)
    }

    /// L during a play with an end plays at 2x to the session end.
    @Test func aShuttleKeyEndsTheBound() async throws {
        let studio = try await studio()
        _ = try await studio.play(from: 24_000, to: 50_000)
        _ = await studio.renderOffline(frames: 4800)

        await studio.perform(.forward)

        _ = await studio.renderOffline(frames: 6 * 4800)
        #expect(try await playerFrame(studio) > 50_000)
        #expect(studio.playback == .playing(Shuttle(direction: .forward, rate: .two)))
        await studio.perform(.pause)
    }

    /// A speed change in a play with an end plays again with no end, on both speed paths: 1x to
    /// 1.5x, and 1.5x to 2x, where a play with no end changes only the unit rate.
    @Test(arguments: zip([Speed.one, .x150], [Speed.x150, .x200]))
    func aSpeedChangeEndsTheBound(before: Speed, after: Speed) async throws {
        let studio = try await studio()
        await studio.changeSpeed(to: before)
        _ = try await studio.play(from: 24_000, to: 50_000)
        _ = await studio.renderOffline(frames: 4800)

        await studio.changeSpeed(to: after)

        try #require(studio.speed == after, "the speed unit loads")
        _ = await studio.renderOffline(frames: 6 * 4800)
        #expect(try await playerFrame(studio) > 50_000)
        #expect(studio.playback == .playing(forward))
        await studio.perform(.pause)
    }

    /// A trim of `c1` to 40 000 during a play with the end 50 000: the play ends at 40 000. The
    /// frames that the Player scheduled before the edit still play; 19 200 output frames are
    /// the 4 chunks of the lookahead, fewer than the 26 000 of the old end.
    @Test func anEditThatShortensTheSessionEndsThePlayThere() async throws {
        let studio = try await studio()
        _ = try await studio.play(from: 24_000, to: 50_000)
        _ = await studio.renderOffline(frames: 4800)

        try studio.edit(ripple: false) { session throws(SessionError) in try session.trim("c1", to: 0..<40_000) }
        let clock = ContinuousClock()
        let limit = clock.now + .seconds(10)
        while await studio.play.player?.session.end != 40_000, clock.now < limit {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await studio.play.player?.session.end == 40_000, "the edit reaches the Player")

        _ = await studio.renderOffline(frames: 3 * 4800)
        await untilStopped(studio)
        #expect(studio.playhead == 40_000)
    }

    // MARK: C14, C18

    /// A stop or a seek during the media check of a play from stopped: the call gives
    /// `.superseded`. The seek to 4800 is before the end, so the user play keeps the end.
    @Test(arguments: [false, true])
    func aCommandDuringTheMediaCheckSupersedesThePlay(seek: Bool) async throws {
        let studio = try await studio()
        let gate = AsyncGate()
        defer { gate.open() }
        studio.environment.beforeMediaCheck = { await gate.wait() }

        let call = Task { try await studio.play(from: 24_000, to: 50_000) }
        await gate.entered()
        await studio.perform(seek ? .seek(.frame(4800)) : .pause)
        gate.open()

        #expect(try await call.value == .superseded)
        guard seek else {
            #expect(studio.playback == .stopped)
            return
        }
        #expect(studio.playback == .playing(forward))
        let out = await studio.renderOffline(frames: 10 * 4800)
        expectMix(slice(out, 0..<45_200), try package.mix(4800..<50_000), "the user play from 4800")
        expectSilence(slice(out, 45_200..<48_000), "no mix after the end")
        await untilStopped(studio)
        #expect(studio.playhead == 50_000)
    }

    @Test func anEngineFailureGivesTheCause() async throws {
        let studio = try await studio()
        studio.environment.startEngine = { _ in throw NSError(domain: NSOSStatusErrorDomain, code: -10_851) }

        let outcome = try await studio.play(from: 24_000, to: 50_000)

        #expect(outcome == .failed(.outputUnavailable(-10_851)))
        #expect(studio.playback == .stopped && studio.playbackStop == .outputUnavailable(-10_851))
    }

    // MARK: C10, C11

    /// A level that holds its first block read: play and locate throw `.busy`, and the stop
    /// gives the playhead. After the level, a locate acts.
    @Test func aPlayDuringALevelThrowsBusy() async throws {
        let studio = try await studio()
        let gate = Gate(limit: nil)
        defer { gate.open() }
        studio.environment.loudnessBlock = { gate.waitOnce() }
        let (playhead, feed) = (studio.playhead, studio.play.feed)

        let leveling = Task { try await studio.level(["c1"], .eachClip) }
        await gate.entered()
        #expect(studio.transport == .leveling)

        await #expect(throws: StudioError.busy) { try await studio.play(from: 0, to: 1000) }
        await #expect(throws: StudioError.busy) { try await studio.locate(1000) }
        #expect(try await studio.stopPlayback() == .state(.stopped(at: playhead)))
        #expect(studio.playback == .stopped && studio.playhead == playhead && studio.play.feed == feed)
        gate.open()
        _ = await leveling.result

        #expect(try await studio.locate(1000) == .state(.stopped(at: 1000)))
    }

    /// A real take: the three calls throw `.busy`, the take goes on, and it writes the frames
    /// that the device gives after the calls.
    @Test func aTransportCallDuringATakeKeepsTheTake() async throws {
        let hal = TestHAL([mic])
        let studio = try await studio(hal)
        try await studio.startRecording(armed: ["t1"], playhead: 96_000)
        let input = SyntheticInput(hal, "mic")
        var clock = DeviceClock(hostNanos: Double(try #require(studio.session.recording).takeStartHostTimeNanos))
        input.play(clock.run(seconds: 0.5))
        await input.wait()
        let playhead = studio.playhead

        await #expect(throws: StudioError.busy) { try await studio.play(from: 0, to: 1000) }
        await #expect(throws: StudioError.busy) { try await studio.locate(1000) }
        await #expect(throws: StudioError.busy) { try await studio.stopPlayback() }

        #expect(studio.transport == .recording(take: 1) && studio.playhead == playhead)
        input.play(clock.run(seconds: 0.5))
        await input.wait()
        await drained(hal, "mic", limit: .seconds(20))
        try await studio.stopRecording()
        let take = studio.session.track("t1")?.clips.first { $0.id != "c1" }
        #expect(take?.length == 48_000, "the take has the frames of both halves")
    }
}
