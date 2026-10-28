import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The app meter around a take: the hand-over, the come back, and no monitor wait in a stop or a
/// Retry Finalize (decision 0015).
extension MonitorAppTests {
    /// Waits until the host clock is `seconds` past the saved take start (as `AppTakeTests`).
    func passTakeTime(_ studio: Studio, seconds: Double) async throws {
        let start = try #require(studio.session.recording?.takeStartHostTimeNanos)
        let end = start &+ UInt64(seconds * 1e9)
        while hostNanosNow() < end { try await Task.sleep(for: .milliseconds(20)) }
    }

    func clips(_ studio: Studio, _ track: TrackID) -> [Clip] {
        studio.session.track(track).map { Array($0.clips) } ?? []
    }

    /// Sends 0.5 s of records into attach number `attach` of `uid`, from the take start.
    func playTake(_ hal: TestHAL, _ uid: String, attach: Int) -> SyntheticInput {
        let input = SyntheticInput(hal, uid)
        var clock = DeviceClock()
        input.play(clock.run(seconds: 0.5), attach: attach, takeStartIn: url)
        return input
    }

    // MARK: C9

    @Test func theTakeReplacesTheAppMonitorTap() async throws {
        let hal = hal()
        let studio = try await studio(hal)
        try await studio.monitor(armed: ["guest"])
        await until(limit: busy, "no monitor tap") { hal.inputs(Self.zoomUID).count == 1 }

        try await studio.startRecording(armed: ["guest"], playhead: 0)
        let input = playTake(hal, Self.zoomUID, attach: 2)
        await input.wait()
        await until(limit: busy, "the monitor tap stays") { hal.calls.contains("destroyTap \(Self.zoomUID)") }
        #expect(taps(hal) == 2, "\(hal.calls)")
        #expect(studio.liveTracks["guest"]?.state == .recording)
        try await passTakeTime(studio, seconds: 0.6)
        try await studio.stopRecording()

        let clip = try #require(clips(studio, "guest").first, "a clip on the app track")
        #expect(clips(studio, "guest").count == 1)
        #expect(abs(clip.length.count - 24_000) <= 1, "the take has each record from the first")
        await studio.settle()
        _ = folder
    }

    @Test func aTakeStartsWhileTheMonitorTapWaits() async throws {
        let hal = hal()
        hal.holdAttach(Self.zoomUID)
        defer { hal.releaseAttach(Self.zoomUID) }
        let studio = try await studio(hal)
        studio.environment.startLimit = .seconds(2)
        studio.environment.stopLimit = .seconds(5)
        try await studio.monitor(armed: ["host", "guest"])
        await until(limit: busy, "the app attach is not at the prompt") { hal.heldAttachCount(Self.zoomUID) == 1 }

        try await studio.startRecording(armed: ["host", "guest"], playhead: 0)
        let input = playTake(hal, "mic", attach: 2)
        await input.wait()
        try await passTakeTime(studio, seconds: 0.6)
        let called = ContinuousClock.now
        try await studio.stopRecording()

        #expect(ContinuousClock.now - called < .seconds(5), "the stop waits for the prompt")
        #expect(clips(studio, "host").count == 1)
        await studio.settle()
        _ = folder
    }

    @Test func aMonitorTapAtThePromptDoesNotDelayTheStart() async throws {
        let hal = hal()
        hal.holdAttach(Self.zoomUID)
        defer { hal.releaseAttach(Self.zoomUID) }
        let studio = try await studio(hal)
        studio.environment.startLimit = .seconds(10)
        studio.environment.stopLimit = .seconds(5)
        try await studio.monitor(armed: ["host", "guest"])
        await until(limit: busy, "the app attach is not at the prompt") { hal.heldAttachCount(Self.zoomUID) == 1 }

        let called = ContinuousClock.now
        try await studio.startRecording(armed: ["host", "guest"], playhead: 0)

        // A wait for the held monitor attach ends only at the start limit (10 s).
        #expect(ContinuousClock.now - called < .seconds(5), "the start waits for the monitor app writer")
        let input = playTake(hal, "mic", attach: 2)
        await input.wait()
        try await passTakeTime(studio, seconds: 0.6)
        try await studio.stopRecording()
        #expect(clips(studio, "host").count == 1)
        await studio.settle()
        _ = folder
    }

    /// A take that starts while the monitor task waits for the microphone gets the only tap.
    @Test func aTakeDuringTheMonitorWaitStartsNoMonitorTap() async throws {
        let hal = hal()
        hal.holdAttach("mic")
        defer { hal.releaseAttach("mic") }
        let studio = try await studio(hal)
        try await studio.monitor(armed: ["host", "guest"])
        await until(limit: busy, "the microphone attach is not held") { hal.heldAttachCount("mic") == 1 }

        let start = Task { @MainActor in try await studio.startRecording(armed: ["host", "guest"], playhead: 0) }
        await until(limit: busy, "the take writer does not attach") { hal.heldAttachCount("mic") == 2 }
        hal.releaseAttach("mic")
        try await start.value
        await until(limit: busy, "no take tap") { taps(hal) == 1 }
        try await passTakeTime(studio, seconds: 0.3)

        #expect(taps(hal) == 1, "\(hal.calls)")
        #expect(liveTaps(hal) == 1)
        try await studio.stopRecording()
        await studio.settle()
        _ = folder
    }

    // MARK: C10

    @Test func theAppMeterComesBackAfterATake() async throws {
        let hal = hal()
        let studio = try await studio(hal)
        try await studio.monitor(armed: ["guest"])
        await until(limit: busy, "no monitor tap") { hal.inputs(Self.zoomUID).count == 1 }
        try await studio.startRecording(armed: ["guest"], playhead: 0)
        let input = playTake(hal, Self.zoomUID, attach: 2)
        await input.wait()
        try await passTakeTime(studio, seconds: 0.6)
        try await studio.stopRecording()

        #expect(studio.liveTracks["guest"]?.state == .monitoring)
        await until(limit: busy, "no tap of the come back") { taps(hal) == 3 }
        await studio.settle()
        _ = folder
    }

    // MARK: C19

    @Test func aHeldMonitorAttachDoesNotDelayTheStop() async throws {
        let hal = hal()
        let studio = try await studio(hal)
        studio.environment.stopLimit = .seconds(5)
        studio.environment.startLimit = .seconds(30)
        try await studio.monitor(armed: ["host", "guest"])
        await until(limit: busy, "no monitor tap") { hal.inputs(Self.zoomUID).count == 1 }
        try await studio.startRecording(armed: ["host", "guest"], playhead: 0)
        let inputs = [playTake(hal, "mic", attach: 2), playTake(hal, Self.zoomUID, attach: 2)]
        for input in inputs { await input.wait() }
        try await passTakeTime(studio, seconds: 0.6)
        hal.holdAttach("mic")
        defer { hal.releaseAttach("mic") }

        let called = ContinuousClock.now
        try await studio.stopRecording()

        // A wait for the held attach ends only at the start limit (30 s).
        #expect(ContinuousClock.now - called < .seconds(10), "the stop waits for the monitor attach")
        #expect(clips(studio, "host").count == 1)
        await until(limit: busy, "the come back does not attach the microphone") { hal.heldAttachCount("mic") == 1 }
        await studio.settle()
        _ = folder
    }

    @Test func aHeldMonitorAttachDoesNotDelayRetryFinalize() async throws {
        let hal = hal()
        let gate = Gate(limit: nil)
        defer { gate.open() }
        let studio = try await studio(hal)
        studio.environment.stopLimit = .seconds(5)
        studio.environment.startLimit = .seconds(30)
        try await studio.monitor(armed: ["host", "guest"])
        await until(limit: busy, "no monitor tap") { hal.inputs(Self.zoomUID).count == 1 }
        try await studio.startRecording(armed: ["host"], playhead: 0)
        let input = playTake(hal, "mic", attach: 2)
        await input.wait()
        try await passTakeTime(studio, seconds: 0.6)
        hal.holdNextDetach(in: gate)
        await #expect(throws: StudioError.writerDidNotStop("USB Mic")) { try await studio.stopRecording() }
        hal.holdAttach("mic")
        defer { hal.releaseAttach("mic") }
        gate.open()

        let called = ContinuousClock.now
        try await studio.retryFinalize()

        // A wait for the held attach ends only at the start limit (30 s).
        #expect(ContinuousClock.now - called < .seconds(10), "Retry Finalize waits for the monitor attach")
        #expect(clips(studio, "host").count == 1)
        await until(limit: busy, "the come back does not attach the microphone") { hal.heldAttachCount("mic") == 1 }
        await studio.settle()
        _ = folder
    }
}
