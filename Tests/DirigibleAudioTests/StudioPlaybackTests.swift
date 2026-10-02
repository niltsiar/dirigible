import CoreAudio
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The Studio transport of decision 0016 (timeline-playback criteria 11, 12, 13, 17, and 21):
/// the playhead, seeks, the end of the material, record at the playhead, and the busy rules. The
/// Player renders offline (`CaptureEnvironment.test`). Tolerance: ± 1e-6 per sample (no gain).
@MainActor
struct StudioPlaybackTests {
    let package: MixPackage
    let mic = InputDevice(
        uid: "mic", name: "USB Mic", nominalRate: 48_000, availableRates: [48_000...48_000], channelsPerBuffer: [1],
        latency: 0)!

    /// Track `t1` on `mic` channel 1, with clip `c1` of 48 000 ramp frames at timeline 0.
    init() throws {
        package = try MixPackage()
        try package.addFile("f1", channels: [ramp(frames: 100_000)])
        try package.addTrack("t1", clip: "c1", file: "f1", start: 0, offset: 0, length: 48_000)
        try package.session.setRoute(Route.device(uid: "mic", channels: .mono(1)), track: "t1")
        try package.session.write(to: package.url)
    }

    func studio(_ hal: TestHAL? = nil) async throws -> Studio {
        let studio = try await Studio.open(package.url)
        studio.environment = .test(hal ?? TestHAL([mic]))
        return studio
    }

    func reading(_ studio: Studio) async throws -> Player.Reading {
        try #require(await studio.play.player?.reading())
    }

    // MARK: Criteria 17 and 21

    @Test func homeEndAndClipEdgesMoveThePlayhead() async throws {
        let studio = try await studio()
        try studio.edit { session throws(SessionError) in
            try session.addTrack("t2", name: "Guest", layout: .mono)
            try session.place(Clip(id: "c2", file: "f1", start: 24_000, offset: 0, length: 48_000), on: "t2")
        }
        #expect(studio.playhead == 48_000, "open: the session end before the edit")

        var visited: [Frames] = []
        for seek: Seek in [.start, .nextClip, .nextClip, .nextClip, .nextClip, .previousClip, .end, .frame(100)] {
            await studio.perform(.seek(seek))
            visited.append(studio.playhead)
        }
        #expect(visited == [0, 24_000, 48_000, 72_000, 72_000, 48_000, 72_000, 100])

        // Space at the end: no play, no change.
        await studio.perform(.seek(.end))
        await studio.perform(.playStop)
        #expect(studio.playback == .stopped && studio.playhead == 72_000)
    }

    /// During play, Previous Clip looks before the playhead - 0.5 s, so a press just after an edge
    /// passes it (code gate 1 item 2). The edges are 0, 24 000, 48 000, and 72 000. Controls: no
    /// 0.5 s during play goes to 48 000; the 0.5 s also when stopped fails
    /// `homeEndAndClipEdgesMoveThePlayhead`.
    @Test func previousClipDuringPlayPassesTheEdgeJustPlayed() async throws {
        let studio = try await studio()
        try studio.edit { session throws(SessionError) in
            try session.addTrack("t2", name: "Guest", layout: .mono)
            try session.place(Clip(id: "c2", file: "f1", start: 24_000, offset: 0, length: 48_000), on: "t2")
        }
        await studio.perform(.seek(.frame(43_200)))
        await studio.perform(.playStop)
        _ = await studio.renderOffline(frames: 9_600)
        // A hang guard: 3 times the worst wait, 12.0 s (run test-pool-health, loops/s3-8.log).
        await until(limit: .seconds(36), "the playhead is 0.1 s past 48 000") { studio.playhead == 52_800 }

        await studio.perform(.seek(.previousClip))

        #expect(studio.playhead == 24_000)
        await studio.perform(.playStop)
    }

    @Test func aReopenedSessionRecordsAfterTheLastClip() async throws {
        let studio = try await studio()
        #expect(studio.playhead == 48_000)

        try await studio.startRecording(armed: ["t1"])

        #expect(studio.session.recording?.playheadFrame == 48_000)
        try await studio.stopRecording()
    }

    // MARK: Criterion 11

    /// Control: the clips end at 48 000, and the take starts at the playhead 96 000.
    @Test func recordStartsAtThePlayhead() async throws {
        let studio = try await studio()
        await studio.perform(.seek(.frame(96_000)))

        try await studio.startRecording(armed: ["t1"])

        #expect(studio.session.recording?.playheadFrame == 96_000)
        try await studio.stopRecording()
    }

    @Test func recordWhilePlayingStopsAndRecordsAtThePosition() async throws {
        let studio = try await studio()
        await studio.perform(.seek(.start))
        await studio.perform(.playStop)
        let out = await studio.renderOffline(frames: 9600)
        for (a, b) in zip(out, try package.mix(0..<9600)) { #expect(maxError(a, b) <= 1e-6, "the mix from 0") }

        try await studio.startRecording(armed: ["t1"])

        #expect(studio.session.recording?.playheadFrame == 9600)
        #expect(studio.playback == .stopped && studio.playhead == 9600)
        #expect(try await !reading(studio).running, "the Player plays into the take")
        try await studio.stopRecording()
    }

    /// Record holds the Player stop in a gate. Space and L in the gap do nothing, and a settle
    /// in the gap waits for the take start (plan gate 1 item 3, gate 2 item 2). Both take paths.
    /// The test waits until the settle waits for its turn of the package writes. 100 main-actor
    /// yields each waited for a job of another suite, so under load the gate limit of 30 s passed
    /// (the timeline-scroll run).
    @Test(arguments: [false, true])
    func noPlayStartsInTheRecordGap(seam: Bool) async throws {
        let gate = AsyncGate()
        let studio = try await studio()
        await studio.perform(.seek(.start))
        await studio.perform(.playStop)
        _ = await studio.renderOffline(frames: 4800)
        studio.environment.beforePlayerStop = { await gate.wait() }

        let take = Task { @MainActor in
            if seam {
                _ = try await studio.startTake(armed: ["t1"], devices: [mic], hostTimeNanos: takeStart)
            } else {
                try await studio.startRecording(armed: ["t1"])
            }
        }
        await gate.entered()
        var settled = false
        let settle = Task { @MainActor in
            await studio.settle()
            settled = true
        }
        await until(limit: .seconds(10), "the settle waits for the take start") { studio.writesWaiting == 1 }
        await studio.perform(.playStop)
        await studio.perform(.forward)
        #expect(!settled, "settle returned before the take start")
        gate.open()
        try await take.value
        await until(limit: .seconds(30), "settle did not return") { settled }
        await settle.value

        // The settle started before Space and L, so it does not stop a play that they started.
        #expect(studio.playback == .stopped)
        #expect(try await !reading(studio).running, "a play started in the gap")
        #expect(studio.lastTake?.take == 1, "settle did not stop the take")
        #expect(try Session(contentsOf: package.url).track("t1")?.clips.count == 1)
        #expect(studio.session.recording == nil && studio.playhead == 4800)
    }

    // MARK: Criterion 12

    /// Control: a finalize that fails (no `Capture/`) leaves the playhead.
    @Test(arguments: [false, true])
    func thePlayheadGoesToTheEndOfTheTake(finalizeFails: Bool) async throws {
        let hal = TestHAL([mic])
        let studio = try await studio(hal)
        let capture = package.url.appending(path: "Capture")
        studio.environment.beforeFinalize = {
            if finalizeFails { try? FileManager.default.removeItem(at: capture) }
        }
        _ = try await studio.startTake(armed: ["t1"], devices: [mic], hostTimeNanos: takeStart)
        let input = SyntheticInput(hal, "mic")
        input.play(records([sine(seconds: 1, rate: 48_000)], layout: [1], rate: 48_000, hostStart: takeStart))
        await input.wait()

        try? await studio.stopRecording()

        if finalizeFails {
            #expect(studio.takeError != nil && studio.playhead == 48_000)
        } else {
            let take = try #require(studio.session.track("t1")?.clips.last)
            #expect(take.start == 48_000 && take.length == 48_000)
            #expect(studio.playhead == 96_000)
        }
    }

    /// A punch-in splits `c1`, and the right part gets a new clip ID. The playhead goes to the
    /// end of the take (24 000), not to the end of that right part (48 000). Found by the code gate.
    @Test func thePlayheadGoesToTheEndOfAPunchIn() async throws {
        let hal = TestHAL([mic])
        let studio = try await studio(hal)
        await studio.perform(.seek(.frame(12_000)))
        _ = try await studio.startTake(armed: ["t1"], devices: [mic], hostTimeNanos: takeStart)
        let input = SyntheticInput(hal, "mic")
        input.play(records([sine(seconds: 0.25, rate: 48_000)], layout: [1], rate: 48_000, hostStart: takeStart))
        await input.wait()

        try await studio.stopRecording()

        let ends = try #require(studio.session.track("t1")?.clips.map(\.end))
        #expect(ends == [12_000, 24_000, 48_000], "the take splits c1")
        #expect(studio.playhead == 24_000)
    }

    // MARK: Criterion 13

    /// Every command but Space does nothing while a take starts or records. Space stops a
    /// take.
    @Test func transportCommandsDoNothingDuringATake() async throws {
        let hal = TestHAL([mic])
        hal.holdLookUps()
        let studio = try await studio(hal)
        await studio.perform(.seek(.frame(1000)))
        let commands: [TransportCommand] = [
            .playStop, .forward, .reverse, .slowForward, .slowReverse, .pause, .stopAndReturn, .seek(.start),
            .seek(.frame(5)), .seek(.nextClip),
        ]

        let start = Task { @MainActor in try await studio.startRecording(armed: ["t1"]) }
        await until(limit: .seconds(10), "the start did not reach the lookup") { hal.heldLookUps == 1 }
        for command in commands { await studio.perform(command) }
        #expect(studio.playback == .stopped && studio.playhead == 1000, "a command acted during the start")
        hal.releaseLookUps()
        try await start.value

        for command in commands.dropFirst() { await studio.perform(command) }
        #expect(studio.playback == .stopped && studio.playhead == 1000, "a command acted during the take")
        #expect(studio.play.player == nil)
        await studio.perform(.playStop)
        #expect(studio.transport == .idle && studio.pendingTake == nil, "Space did not stop the take")
    }

    @Test func settleStopsPlayback() async throws {
        let studio = try await studio()
        await studio.perform(.seek(.start))
        await studio.perform(.playStop)
        _ = await studio.renderOffline(frames: 4800)
        #expect(studio.playback == .playing(Shuttle(direction: .forward, rate: .one)))

        await studio.settle()

        #expect(studio.playback == .stopped && studio.playhead == 4800)
        #expect(try await !reading(studio).running)
    }

    // MARK: The end of the material (slice 2 change)

    /// At 2x the Player position passes the end by one frame; the Studio playhead stops at the
    /// end (forward) or at 0 (reverse).
    @Test(arguments: [(Frames(47_001), TransportCommand.forward, Frames(48_000)), (1001, .reverse, 0)])
    func theEndOfTheMaterialStopsAtTheEnd(from: Frames, command: TransportCommand, end: Frames) async throws {
        let studio = try await studio()
        await studio.perform(.seek(.frame(from)))
        await studio.perform(command)
        await studio.perform(command)
        #expect(studio.playback != .stopped)

        _ = await studio.renderOffline(frames: 1000)

        // A hang guard: 3 times the worst wait, 6.3 s (run test-pool-health, loops/s3-8.log).
        await until(limit: .seconds(19), "the play did not end") { studio.playback == .stopped }
        #expect(studio.playhead == end)
        #expect(try await !reading(studio).running)
    }

    /// Shift-Space goes back to the start point; K keeps the position; L at 4x stays at 4x.
    @Test func pauseKeepsThePositionAndReturnGoesBack() async throws {
        let studio = try await studio()
        await studio.perform(.seek(.frame(2400)))
        await studio.perform(.forward)
        _ = await studio.renderOffline(frames: 4800)
        await studio.perform(.pause)
        #expect(studio.playback == .stopped && studio.playhead == 7200)
        await studio.perform(.forward)
        _ = await studio.renderOffline(frames: 4800)
        await studio.perform(.stopAndReturn)
        #expect(studio.playback == .stopped && studio.playhead == 7200)
    }

    /// A change of the player output drops a stopped Player, so the next play makes one with
    /// the new output (plan fix check). Control: another change keeps it.
    @Test func aNewPlayerOutputReplacesAStoppedPlayer() async throws {
        let studio = try await studio()
        await studio.perform(.seek(.start))
        await studio.perform(.playStop)
        await studio.perform(.playStop)
        studio.environment.beforePlayerStop = {}
        #expect(studio.play.player != nil)

        studio.environment.playerOutput = .device

        #expect(studio.play.player == nil)
    }
}
