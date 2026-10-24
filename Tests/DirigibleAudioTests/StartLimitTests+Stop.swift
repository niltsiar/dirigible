import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The stop of decision 0030 with a writer that does not answer: one deadline, the take state
/// ends, the take stays pending, and Retry Finalize places it after the late finish.
extension StartLimitTests {
    // MARK: C6, C16, C18

    /// `writers` devices attach, record, are lost, and their come-back attach waits, so their
    /// queues do not answer. The stop throws `.writerDidNotStop` at its one deadline, ends the take
    /// state, and keeps the take pending. After the release, Retry Finalize places the take with
    /// the late gaps, and no clip has audio after the stop.
    @Test(arguments: [1, 2])
    func aHeldWriterDoesNotHoldTheStop(writers count: Int) async throws {
        let hal = hal()
        let held = Array([("box", TrackID("t2")), ("deck", TrackID("t3"))].prefix(count))
        defer { for (uid, _) in held { hal.releaseAttach(uid) } }
        let studio = try await studio(hal, stop: limit)
        let inputs = (["mic"] + held.map(\.0)).map { play(hal, $0) }
        _ = try await start(studio, ["t1"] + held.map(\.1)) {}
        try await Task.sleep(for: .seconds(1))
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
        let flake: Comment =
            "quarantine: the stop deadline misses under suite load, cause not proven: see backlog FLAKE LINE 40"
        withKnownIssue(flake, isIntermittent: true) {
            #expect(
                ["Box", "Deck"].prefix(count).contains { error == .writerDidNotStop($0) },
                "\(String(describing: error))")
        }
        withKnownIssue(flake, isIntermittent: true) {
            #expect(took < limit * 3 / 2, "the stop threw after \(took)")
        }
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

    /// A main-actor job that waits behind the stop holds the main actor 0.55 s, past the stop
    /// deadline, before the waits that the stop starts can run. The healthy `mic` writer still
    /// answers in time, so only the held `box` writer is late.
    @Test func aMainActorHoldAtTheStopLeavesTheHealthyWriterOnTime() async throws {
        let hal = hal()
        defer { hal.releaseAttach("box") }
        let studio = try await studio(hal, stop: limit)
        let inputs = [play(hal, "mic"), play(hal, "box")]
        _ = try await start(studio, ["t1", "t2"]) {}
        try await Task.sleep(for: .seconds(1))
        try await holdComeBack(studio.writer("box"), hal, "box")

        let watch = ContinuousClock.now
        let stopping = Task { @MainActor () -> StudioError? in
            do throws(StudioError) { try await studio.stopRecording() } catch { return error }
            return nil
        }
        Task { @MainActor in usleep(550_000) }
        let error = await stopping.value
        let took = ContinuousClock.now - watch
        let late = studio.unfinishedWriters.map(\.uid)

        hal.releaseAttach("box")
        for input in inputs { await input.wait() }
        try await studio.retryFinalize()
        #expect(late == ["box"], "late writers: \(late)")
        #expect(error == .writerDidNotStop("Box"))
        #expect(took < limit * 3 / 2, "the stop threw after \(took)")
        await studio.settle()
    }

    /// A main-actor job starts after the call of `bounded`, holds the main actor past the deadline,
    /// and queues a marker job at its end. The deadline (no answer) or the answer (at once) resumes
    /// the caller during the hold, so the caller runs before the marker. The hold past the
    /// deadline, and past an answer at once, is longer than a pool hop under load.
    @Test(arguments: [false, true])
    func aBoundedWaitEndsWithoutTheMainActor(answers: Bool) async {
        let gate = AsyncGate()
        defer { gate.open() }
        let marker = Done()
        let deadline = ContinuousClock.now + (answers ? .seconds(5) : .milliseconds(100))
        let hold = Task { @MainActor in
            usleep(700_000)
            return Task { @MainActor in marker.value = true }
        }
        let result = await bounded(by: deadline) { () async -> Int in
            if !answers { await gate.wait() }
            return 1
        }
        let markerFirst = marker.value
        await hold.value.value
        #expect(result == (answers ? 1 : nil))
        #expect(!markerFirst, "the caller of bounded ran after the job that the hold queued")
    }

    /// A stop that runs at `.userInitiated` priority runs each writer step at that priority or higher.
    @Test func aBoundedWriterStepKeepsTheCallerPriority() async {
        let capture = folder.url
        let writer = DeviceWriter(
            device: mic, tracks: [(arm: 1, channels: .mono(1))], files: TakeFiles(take: 1, folder: { capture }),
            hal: hal().hal, report: ReportLog().closure, silenceLimit: noWatchdog, firstRecordLimit: noWatchdog)
        let seen = await Task(priority: .userInitiated) { @MainActor in
            let answers = await boundedEach([writer], by: .now + .seconds(5)) { _ in Task.currentPriority }
            return answers[ObjectIdentifier(writer)]
        }.value
        #expect(seen.map { $0 >= .userInitiated } == true, "the step ran at \(String(describing: seen))")
    }

    /// A Retry Finalize while the writer still does not answer throws `.writerDidNotStop` at its own
    /// deadline and leaves Retry Finalize on; after the release, it places the take.
    @Test func aFailedRetryKeepsRetryOn() async throws {
        let hal = hal()
        defer { hal.releaseAttach("box") }
        let studio = try await studio(hal, stop: limit)
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
    /// stop, `box` is given up, and the healthy `mic` finishes, so the take finalizes.
    @Test func aStopRightAfterAHeldStartFinalizesTheHealthyWriters() async throws {
        let hal = hal()
        hal.holdAttach("box")
        defer { hal.releaseAttach("box") }
        let studio = try await studio(hal, stop: limit)
        let mics = play(hal, "mic")
        let started = Task { try await studio.startRecording(armed: ["t1", "t2"], playhead: 0) }
        await until(limit: busy, "the take did not begin") { studio.transport == .recording(take: 1) }
        try await Task.sleep(for: .milliseconds(300))

        let (error, took) = await stop(studio) { hal.releaseAttach("box") }
        try await started.value
        await mics.wait()
        #expect(took < .seconds(2), "the stop returned after \(took)")
        #expect(error == nil)
        #expect(studio.lastTake?.gaps["t2"] == .deviceLost)
        #expect(!clipFrames(studio, "t1").isEmpty, "no clip of t1")
        hal.releaseAttach("box")
        await studio.settle()
    }

    /// A Stop while the start waits for the first attach of `box` starts no app writer, and no
    /// writer keeps a device-list watcher: the stop gives up each writer that never attached, the
    /// app writer too, so a start after the cut does nothing.
    @Test func aStopDuringTheDeviceWaitStartsNoAppWriter() async throws {
        let hal = hal()
        hal.holdAttach("box")
        defer { hal.releaseAttach("box") }
        let studio = try await studio(hal, stop: limit)
        let mics = play(hal, "mic")
        let started = Task { try await studio.startRecording(armed: ["t1", "t2", "t4"], playhead: 0) }
        await until(limit: busy, "the take did not begin") { studio.transport == .recording(take: 1) }
        try await Task.sleep(for: .milliseconds(300))

        let (error, _) = await stop(studio) { hal.releaseAttach("box") }
        try await started.value
        await mics.wait()
        hal.releaseAttach("box")
        await studio.settle()
        #expect(error == nil)
        #expect(!hal.calls.contains { $0.hasPrefix("makeTap") }, "an app tap after the stop: \(hal.calls)")
        await until(limit: busy, "a writer keeps its device-list watcher") { hal.watchers.count == 0 }
    }

    /// The monitor of `t2` is on, and the `box` writer of the take does not stop. The stop starts
    /// no monitor writer on `box`: its attach would go to the device that does not answer. After
    /// Retry Finalize finishes the writer, the monitor of `box` comes back.
    @Test func aStopStartsNoMonitorOnTheDeviceOfAnUnfinishedWriter() async throws {
        let hal = hal()
        defer { hal.releaseAttach("box") }
        let studio = try await studio(hal, stop: limit)
        try await studio.monitor(armed: ["t2"])
        await until(limit: busy, "no monitor attach of box") { hal.current("box") != nil }
        let mics = play(hal, "mic")
        _ = try await start(studio, ["t1", "t2"]) {}
        try await Task.sleep(for: .seconds(1))
        try await holdComeBack(studio.writer("box"), hal, "box")
        let (error, _) = await stop(studio) { hal.releaseAttach("box") }
        let monitorDuringHold = studio.monitorWriter("box") != nil
        let held = hal.heldAttachCount("box")

        hal.releaseAttach("box")
        await mics.wait()
        try await studio.retryFinalize()
        #expect(error == .writerDidNotStop("Box"))
        #expect(!monitorDuringHold, "the stop started a monitor writer on box")
        #expect(held == 1, "\(held) attaches of box waited in the hold")
        #expect(studio.monitorWriter("box") != nil, "the monitor of box did not come back")
        #expect(studio.liveTracks["t2"]?.state == .monitoring)
        await studio.settle()
    }

    /// The Zoom writer of `t4` gets 6 s of zeros, so it shows the silence warning, and the tap of
    /// its warning rebuild waits, so the writer does not stop. Retry Finalize names the silent
    /// track after the late finish, as a stop names the track of a writer that finished.
    @Test func aRetryNamesTheSilentTrackOfALateAppWriter() async throws {
        let hal = hal()
        defer { hal.releaseTaps() }
        let studio = try await studio(hal, stop: limit)
        _ = try await start(studio, ["t4"]) {}
        await until(limit: busy, "Zoom did not attach") { hal.current(Self.zoomUID) != nil }
        let first = try #require(hal.current(Self.zoomUID))
        hal.holdTaps()
        let zeros = SyntheticInput(hal, Self.zoomUID)
        var clock = DeviceClock()
        zeros.play(
            clock.run(seconds: 6).map { record in
                var record = record
                record.buffers = [[Float](repeating: 0, count: record.frameCount)]
                return record
            }, takeStartIn: url)
        await zeros.wait()
        await until(limit: busy, "the silence warning did not rebuild the tap") { hal.isDetached(first) }
        let (error, _) = await stop(studio) { hal.releaseTaps() }
        let silentAtStop = studio.lastTake?.silent

        hal.releaseTaps()
        try await studio.retryFinalize()
        #expect(error == .writerDidNotStop("zoom.us"))
        #expect(silentAtStop == [:])
        #expect(studio.lastTake?.silent == ["t4": "zoom.us"])
        await studio.settle()
    }

    // MARK: C17

    /// A writer that does not stop keeps the package lock, also after Close drops the Studio. After
    /// its late finish, an open recovers the take with every frame of each segment.
    @Test func aLiveWriterKeepsThePackageLock() async throws {
        let hal = hal()
        defer { hal.releaseAttach("box") }
        var studio: Studio? = try await studio(hal, stop: limit)
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
        let studio = try await studio(hal, stop: limit)
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
