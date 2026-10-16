import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The stop of decision 0030 with a writer that does not answer: one deadline, the take state
/// ends, the take stays pending, and Retry Finalize places it after the late finish.
extension StartLimitTests {
    // MARK: C6, C16, C18, C19

    enum Bound: CaseIterable, Sendable {
        /// `stopLimit` with no grace, and a Stop 1 s into the take.
        case limit
        /// `stopLimit` of 1 ms and `stopGrace`, and a Stop just after the start returns.
        case grace
    }

    /// `writers` devices attach, record, are lost, and their come-back attach waits, so their
    /// queues do not answer. The stop throws `.writerDidNotStop` at its one deadline, ends the take
    /// state, and keeps the take pending. After the release, Retry Finalize places the take with
    /// the late gaps, and no clip has audio after the stop.
    @Test(arguments: [1, 2], Bound.allCases)
    func aHeldWriterDoesNotHoldTheStop(writers count: Int, bound: Bound) async throws {
        let hal = hal()
        let held = Array([("box", TrackID("t2")), ("deck", TrackID("t3"))].prefix(count))
        defer { for (uid, _) in held { hal.releaseAttach(uid) } }
        let studio = try await studio(
            hal, stop: bound == .limit ? limit : .milliseconds(1), grace: bound == .limit ? .zero : limit)
        let inputs = (["mic"] + held.map(\.0)).map { play(hal, $0) }
        _ = try await start(studio, ["t1"] + held.map(\.1)) {}
        if bound == .limit { try await Task.sleep(for: .seconds(1)) }
        // The come-back appearance gets records past any stop time.
        let late = held.map { (uid, _) in
            let input = SyntheticInput(hal, uid)
            var clock = DeviceClock(hostNanos: Double(hostNanosNow()))
            input.play(clock.run(seconds: 5), attach: 2)
            return input
        }
        for (uid, _) in held { try await holdComeBack(studio.writer(uid), hal, uid) }
        let takeStartHost = try #require(studio.session.recording?.takeStartHostTimeNanos)

        let (error, took) = await stop(studio) { for (uid, _) in held { hal.releaseAttach(uid) } }
        let stopHost = hostNanosNow()
        #expect(
            ["Box", "Deck"].prefix(count).contains { error == .writerDidNotStop($0) }, "\(String(describing: error))")
        #expect(took < limit * 3 / 2, "the stop threw after \(took)")
        #expect(studio.takeError == error)
        #expect(studio.lastTake != nil && studio.lastTake?.gaps["t1"] == nil)
        #expect(studio.sleepAssertion == nil, "the sleep assertion stays")
        #expect(studio.pendingTake?.take == 1)
        let first = url.appending(path: "Capture/take1-1-1.caf")
        #expect(try AVAudioFile(forReading: first).length > 0)

        for (uid, _) in held { hal.releaseAttach(uid) }
        for input in inputs + late { await input.wait() }
        try await studio.retryFinalize()
        for (_, track) in held { #expect(studio.lastTake?.gaps[track] == .deviceLost) }
        #expect(!clipFrames(studio, "t1").isEmpty, "no clip of t1")
        let framesToStop = Int((stopHost - takeStartHost) / 1_000_000 * 48)
        for (_, track) in held {
            let frames = clipFrames(studio, track).reduce(0, +)
            #expect(frames <= framesToStop + 480, "\(track): \(frames) frames, \(framesToStop) to the stop")
        }
        await studio.settle()
    }

    /// A Retry Finalize while the writer still does not answer throws `.writerDidNotStop` at its own
    /// deadline and leaves Retry Finalize on; after the release, it places the take.
    @Test func aFailedRetryKeepsRetryOn() async throws {
        let hal = hal()
        defer { hal.releaseAttach("box") }
        let studio = try await studio(hal, stop: limit, grace: .zero)
        let inputs = [play(hal, "mic"), play(hal, "box")]
        _ = try await start(studio, ["t1", "t2"]) {}
        try await Task.sleep(for: .seconds(1))
        try await holdComeBack(studio.writer("box"), hal, "box")
        let (error, _) = await stop(studio) { hal.releaseAttach("box") }
        #expect(error == .writerDidNotStop("Box"))

        let watch = ContinuousClock.now
        await #expect(throws: StudioError.writerDidNotStop("Box")) { try await studio.retryFinalize() }
        let took = ContinuousClock.now - watch
        #expect(took < limit * 3 / 2, "the retry threw after \(took)")
        #expect(studio.transport == .idle)
        #expect(studio.pendingTake?.take == 1)
        #expect(studio.takeError == .writerDidNotStop("Box"))

        hal.releaseAttach("box")
        for input in inputs { await input.wait() }
        try await studio.retryFinalize()
        #expect(studio.pendingTake == nil)
        #expect(studio.lastTake?.gaps["t2"] == .deviceLost)
        await studio.settle()
    }

    /// A Stop right after Record, while the first attach of `box` waits: the start returns at the
    /// stop, `box` is given up, and the grace after the start step lets the healthy `mic` (a 20 ms
    /// detach) finish, with a `stopLimit` of 1 ms. Control: with no grace, `mic` misses the stop.
    @Test(arguments: [true, false])
    func aStopRightAfterAHeldStartFinalizesTheHealthyWriters(grace: Bool) async throws {
        let hal = hal()
        hal.holdAttach("box")
        defer { hal.releaseAttach("box") }
        hal.delayDetach("mic", by: .milliseconds(20))
        let studio = try await studio(hal, stop: .milliseconds(1), grace: grace ? .seconds(1) : .zero)
        let mics = play(hal, "mic")
        let started = Task { try await studio.startRecording(armed: ["t1", "t2"], playhead: 0) }
        await until(limit: busy, "the take did not begin") { studio.transport == .recording(take: 1) }
        try await Task.sleep(for: .milliseconds(300))

        let (error, took) = await stop(studio) { hal.releaseAttach("box") }
        try await started.value
        await mics.wait()
        #expect(took < .seconds(2), "the stop returned after \(took)")
        if grace {
            #expect(error == nil)
            #expect(studio.lastTake?.gaps["t2"] == .deviceLost)
            #expect(!clipFrames(studio, "t1").isEmpty, "no clip of t1")
        } else {
            #expect(error == .writerDidNotStop("USB Mic"))
        }
        hal.releaseAttach("box")
        await studio.settle()
    }

    // MARK: C17

    /// A writer that does not stop keeps the package lock, also after Close drops the Studio. After
    /// its late finish, an open recovers the take with every frame of each segment.
    @Test func aLiveWriterKeepsThePackageLock() async throws {
        let hal = hal()
        defer { hal.releaseAttach("box") }
        var studio: Studio? = try await studio(hal, stop: limit, grace: .zero)
        let inputs = [play(hal, "mic"), play(hal, "box")]
        _ = try await start(studio!, ["t1", "t2"]) {}
        try await Task.sleep(for: .seconds(1))
        try await holdComeBack(studio!.writer("box"), hal, "box")
        weak let writer = studio!.writer("box")
        let (error, _) = await stop(studio!) { hal.releaseAttach("box") }
        #expect(error == .writerDidNotStop("Box"))
        await studio!.settle()
        studio = nil

        await #expect(throws: StudioError.locked) { _ = try await Studio.open(url) }
        hal.releaseAttach("box")
        for input in inputs { await input.wait() }
        await until(limit: busy, "the writer did not finish") { writer == nil }
        var segments: [String: Int64] = [:]
        for stem in try captureStems() {
            let file = try AVAudioFile(forReading: url.appending(path: "Capture/\(stem).caf"))
            segments[stem] = file.length
        }
        let reopened = try await Studio.open(url)
        #expect(reopened.session.recording == nil, "the open did not recover the take")
        for (stem, frames) in segments where frames > 0 {
            let clip = reopened.session.tracks.flatMap(\.clips).first { $0.id.rawValue == stem }
            #expect(clip.map { Int64($0.length.count) } == frames, "\(stem)")
        }
        await reopened.settle()
    }

    // MARK: C16, CLI

    /// `dirigible record` calls `record`: a held writer makes it throw `.writerDidNotStop` with
    /// `lastTake` set, so the command prints the gaps and "The take is still pending." (exit 2).
    @Test func aTimedTakeWithAHeldWriterKeepsItsResult() async throws {
        let hal = hal()
        defer { hal.releaseAttach("box") }
        let studio = try await studio(hal, stop: limit, grace: .zero)
        let length = AsyncGate()
        studio.environment.takeLength = { _ in await length.wait() }
        let inputs = [play(hal, "mic"), play(hal, "box")]
        let done = Done()
        let record = Task { @MainActor () -> StudioError? in
            defer { done.value = true }
            do throws(StudioError) {
                _ = try await studio.record(armed: ["t1", "t2"], playhead: 0, for: .seconds(60))
            } catch {
                return error
            }
            return nil
        }
        await until(limit: busy, "the take did not begin") { studio.transport == .recording(take: 1) }
        try await Task.sleep(for: .seconds(1))
        try await holdComeBack(studio.writer("box"), hal, "box")
        length.open()
        await until(limit: .seconds(5), "the record waits for a held writer") { done.value }
        if !done.value { hal.releaseAttach("box") }
        let error = await record.value

        #expect(error == .writerDidNotStop("Box"))
        #expect(studio.lastTake?.take == 1)
        hal.releaseAttach("box")
        for input in inputs { await input.wait() }
        try await studio.retryFinalize()
        await studio.settle()
    }
}
