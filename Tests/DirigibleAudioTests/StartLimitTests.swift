import CoreAudio
import DirigibleCore
import Foundation
import Testing
import os

@testable import DirigibleAudio

/// One deadline for the take start and one for the stop (decision 0030): a writer whose queue
/// waits in a HAL call holds neither, a stop never waits for a writer that never attached, and
/// no finalize runs while a writer that attached does not answer.
@MainActor @Suite(.serialized)
struct StartLimitTests {
    static let zoom = "us.zoom.xos"
    static let zoomUID = "app:us.zoom.xos"
    /// The limit of a wait for a Studio state, which a report hop sets on the main actor. A late
    /// Retry Finalize also takes it as its stop limit: under suite load, the late finish of a
    /// released writer can take more than a short stop limit.
    let busy = Duration.seconds(20)
    /// The start or stop limit of a limit test. A bound of 1.5 limits passes one deadline for the
    /// whole operation and fails one limit for each of two waits.
    let limit = Duration.milliseconds(500)
    let folder: TemporaryFolder
    let url: URL
    let mic = Self.device("mic", "USB Mic")
    let box = Self.device("box", "Box")
    let deck = Self.device("deck", "Deck")

    static func device(_ uid: String, _ name: String) -> InputDevice {
        InputDevice(
            uid: uid, name: name, nominalRate: 48_000, availableRates: [48_000...48_000], channelsPerBuffer: [1],
            latency: 0)!
    }

    /// What the app lookup of Zoom finds: `processes`, the speaker output, and a mono aggregate.
    static func found(_ processes: [AudioObjectID]) -> AppFound {
        AppFound(
            key: AppKey(processes: processes, output: "BuiltInSpeakerDevice"), output: "BuiltInSpeakerDevice",
            device: InputDevice(
                uid: zoomUID, name: zoom, nominalRate: 48_000, availableRates: [48_000...48_000],
                channelsPerBuffer: [1], latency: 0)!,
            playing: !processes.isEmpty)
    }

    /// `t1` on `mic`, `t2` on `box`, `t3` on `deck`, and `t4` on Zoom, all mono.
    init() throws {
        folder = try TemporaryFolder()
        url = folder.url.appending(path: "Show.dirigible")
        var session = Session(sampleRate: 48_000)
        for (id, name) in [("t1", "Host"), ("t2", "Guest"), ("t3", "Other"), ("t4", "Call")] {
            try session.addTrack(TrackID(id), name: name, layout: .mono)
        }
        try session.setRoute(.device(uid: "mic", channels: .mono(1)), track: "t1")
        try session.setRoute(.device(uid: "box", channels: .mono(1)), track: "t2")
        try session.setRoute(.device(uid: "deck", channels: .mono(1)), track: "t3")
        try session.setRoute(.app(bundleID: Self.zoom), track: "t4")
        try session.write(to: url)
    }

    func hal() -> TestHAL {
        let hal = TestHAL([mic, box, deck])
        hal.setApp(Self.zoom, Self.found([41]), name: "zoom.us")
        return hal
    }

    func studio(_ hal: TestHAL, start: Duration = .seconds(10), stop: Duration = .seconds(10)) async throws -> Studio {
        let studio = try await Studio.open(url)
        studio.environment = .test(hal)
        studio.environment.startLimit = start
        studio.environment.stopLimit = stop
        return studio
    }

    /// Plays 3 s of records of `uid` at the pace of the clock from the take start.
    func play(_ hal: TestHAL, _ uid: String) -> SyntheticInput {
        let input = SyntheticInput(hal, uid)
        var clock = DeviceClock(hostNanos: Double(takeStart) + 100_000_000)
        input.play(clock.run(seconds: 3), pace: .realTime, takeStartIn: url)
        return input
    }

    /// Starts a take of `armed` and returns the time from the begin (`afterStart`) to the return.
    /// A start that does not return in 5 s is an issue; then `release` lets it end. A test that
    /// holds no writer at the start calls `startRecording`: the wall cap of this wait also counts
    /// the main-actor holds of other suites.
    func start(_ studio: Studio, _ armed: [TrackID], release: () -> Void) async throws -> Duration {
        let begun = OSAllocatedUnfairLock<ContinuousClock.Instant?>(initialState: nil)
        studio.environment.afterStart = { begun.withLock { $0 = .now } }
        let done = Done()
        let task = Task { @MainActor in
            try await studio.startRecording(armed: armed, playhead: 0)
            done.value = true
            return ContinuousClock.now
        }
        await until(limit: .seconds(5), "the start waits for a held writer") { done.value }
        if !done.value { release() }
        let returned = try await task.value
        return returned - (begun.withLock { $0 } ?? returned)
    }

    /// Stops the take and returns its error and the time from the call to the return. A stop that
    /// does not return in `wait` (counted as `until` counts it) is an issue; then `release` lets it end.
    func stop(
        _ studio: Studio, wait: Duration = .seconds(5), release: () -> Void
    ) async -> (error: StudioError?, took: Duration) {
        let done = Done()
        let watch = ContinuousClock.now
        let task = Task { @MainActor () -> (StudioError?, Duration) in
            var error: StudioError?
            do throws(StudioError) { try await studio.stopRecording() } catch let failure { error = failure }
            done.value = true
            return (error, ContinuousClock.now - watch)
        }
        await until(limit: wait, "the stop waits for a held writer") { done.value }
        if !done.value { release() }
        return await task.value
    }

    /// The device `uid` of `writer` is lost, and its come-back attach waits in the hold of the HAL,
    /// so the queue of the writer does not answer. Waits until the attach call waits.
    func holdComeBack(_ writer: DeviceWriter?, _ hal: TestHAL, _ uid: String) async throws {
        hal.holdAttach(uid)
        let writer = try #require(writer)
        writer.post(.alive(false), from: hal.current(uid))
        writer.post(.devicesChanged, from: nil)
        await until(limit: busy, "the come-back attach of \(uid) did not wait") { hal.heldAttachCount(uid) >= 1 }
    }

    /// The frames of each clip of `track`.
    func clipFrames(_ studio: Studio, _ track: TrackID) -> [Int] {
        studio.session.track(track)?.clips.map(\.length.count) ?? []
    }

    /// The segment stems in `Capture/`.
    func captureStems() throws -> [String] {
        let capture = url.appending(path: "Capture")
        guard FileManager.default.fileExists(atPath: capture.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: capture.path).map {
            URL(filePath: $0).deletingPathExtension().lastPathComponent
        }.sorted()
    }

    // MARK: C5

    enum Before: CaseIterable, Sendable {
        case nothing
        /// A monitor writer runs on `box` before the take.
        case monitor
        /// A monitor toggle just before Record releases a monitor writer whose come-back attach
        /// waits, so its monitor turn waits up to `stopLimit`.
        case monitorTurnHeld
    }

    /// `box` does not answer its first attach. The start returns at its one deadline (`startApps`
    /// and the hand-over both wait for `box`), `t2` shows `.notStarted`, and `t1` records. `t3`,
    /// whose attach throws, keeps `.deviceLost`. After the release, the first report of `box`
    /// gives `.recording`, and each monitor writer is finished.
    @Test(arguments: Before.allCases)
    func aDeviceThatDoesNotStartDoesNotHoldTheStart(before: Before) async throws {
        let hal = hal()
        hal.failAttach { uid, _ in uid == "deck" ? .status(kAudioHardwareBadDeviceError) : nil }
        let studio = try await studio(hal, start: limit)
        var monitorInput: DeviceInput?
        if before != .nothing {
            try await studio.monitor(armed: ["t2"])
            await until(limit: busy, "no monitor attach of box") { hal.current("box") != nil }
            monitorInput = hal.current("box")
        }
        if before == .monitorTurnHeld {
            try await holdComeBack(studio.monitorWriter("box"), hal, "box")
        } else {
            hal.holdAttach("box")
        }
        defer { hal.releaseAttach("box") }
        var toggle: Task<Void, Never>?
        if before == .monitorTurnHeld {
            toggle = Task { try? await studio.monitor(armed: []) }
            await until(limit: busy, "the toggle did not release the monitor writer") {
                studio.monitorWriter("box") == nil
            }
        }
        let mics = play(hal, "mic")
        let boxes = before == .nothing ? play(hal, "box") : nil

        let took = try await start(studio, ["t1", "t2", "t3"]) { hal.releaseAttach("box") }
        let shown = studio.liveTracks["t2"]?.state
        await until(limit: busy, "t3 is not lost") { studio.liveTracks["t3"]?.state == .deviceLost }
        try await Task.sleep(for: .milliseconds(1_200))
        hal.releaseAttach("box")
        await until(limit: busy, "t2 does not record after the release") {
            studio.liveTracks["t2"]?.state == .recording
        }
        // The toggle returns when the finish of its released monitor writer ends.
        await toggle?.value
        if before == .monitor, let monitorInput {
            await until(limit: busy, "the monitor writer of box did not finish") { hal.isDetached(monitorInput) }
        }
        let monitorGone = studio.monitorWriter("box") == nil
        await mics.wait()
        await boxes?.wait()
        try await studio.stopRecording()

        #expect(took < limit * 3 / 2, "the start returned \(took) after the begin")
        #expect(shown == .notStarted)
        #expect(studio.lastTake?.gaps["t3"] == .deviceLost)
        #expect(clipFrames(studio, "t1").reduce(0, +) >= 48_000)
        if before == .nothing { #expect(clipFrames(studio, "t2").reduce(0, +) > 0, "no frames of box") }
        #expect(monitorGone, "a monitor writer of box runs during the take")
        await studio.settle()
    }

    // MARK: C13

    enum Kind: CaseIterable, Sendable { case device, playingApp, appWithNoProcess }

    /// The first attach of each writer reports the state of its track once, so a late first attach
    /// replaces the state of the take start.
    @Test(arguments: Kind.allCases)
    func theFirstAttachOfEachWriterKindReportsItsState(kind: Kind) async throws {
        let hal = TestHAL([mic])
        let log = ReportLog()
        let capture = folder.url
        let files = TakeFiles(take: 1, folder: { capture })
        let writer: DeviceWriter
        if kind == .device {
            writer = DeviceWriter(
                device: mic, tracks: [(arm: 1, channels: .mono(1))], files: files, hal: hal.hal, report: log.closure,
                silenceLimit: noWatchdog, firstRecordLimit: noWatchdog)
        } else {
            let found = Self.found(kind == .playingApp ? [41] : [])
            hal.setApp(Self.zoom, found)
            writer = DeviceWriter(
                device: found.device, tracks: [(arm: 1, channels: .mono(1))], files: files, hal: hal.hal,
                report: log.closure, silenceLimit: noWatchdog, firstRecordLimit: noWatchdog, app: Self.zoom)
        }
        writer.start()
        await writer.started()
        await writer.finish()

        #expect(log.states(arm: 1) == [kind == .appWithNoProcess ? .waitingForApp : .recording])
    }

    // MARK: C6, C14

    /// A writer that the stop gave up while its first attach waited tears that attach down at once,
    /// with no queued finish: the writer queue can run a drain tick before the finish.
    @Test func anAbandonedWriterTearsDownItsLateAttachAtOnce() async throws {
        let hal = hal()
        hal.holdAttach("box")
        defer { hal.releaseAttach("box") }
        let log = ReportLog()
        let capture = folder.url
        let writer = DeviceWriter(
            device: box, tracks: [(arm: 1, channels: .mono(1))], files: TakeFiles(take: 1, folder: { capture }),
            hal: hal.hal, report: log.closure, silenceLimit: noWatchdog, firstRecordLimit: noWatchdog)
        writer.start()
        await until(limit: busy, "the first attach of box did not wait") { hal.heldAttachCount("box") >= 1 }
        #expect(writer.abandon())

        hal.releaseAttach("box")
        await until(limit: busy, "the held attach did not return") { hal.calls.contains("attach box") }
        await until(limit: .seconds(3), "the late attach did not tear down") { hal.calls.contains("detach box") }
        #expect(!log.states(arm: 1).contains(.recording), "an abandoned writer reported recording")
        await writer.finish()
    }

    enum Start: CaseIterable, Sendable {
        /// The first attach of `box` waits in the HAL.
        case heldDevice
        /// The tap of Zoom waits, as at the System Audio Recording prompt.
        case heldApp
        /// The attach of `box` throws, so its writer is lost from the start and retries.
        case lost
    }

    /// A writer that never attached holds no audio: the stop gives it up and does not wait for it,
    /// with a `stopLimit` of 1 h. The take finalizes with the `t1` clip, and the late track gets a
    /// gap and no clip. A late attach tears down and writes nothing; the writer then goes, the
    /// package opens again, and a second take records on the device.
    @Test(arguments: Start.allCases)
    func aWriterThatNeverAttachedDoesNotHoldTheStop(start: Start) async throws {
        let hal = hal()
        switch start {
        case .heldDevice: hal.holdAttach("box")
        case .heldApp: hal.holdTaps()
        case .lost: hal.failAttach { uid, _ in uid == "box" ? .status(kAudioHardwareBadDeviceError) : nil }
        }
        let release = {
            hal.releaseAttach("box")
            hal.releaseTaps()
        }
        defer { release() }
        let (track, uid) = start == .heldApp ? (TrackID("t4"), Self.zoomUID) : (TrackID("t2"), "box")
        var studio: Studio? = try await studio(hal, start: limit, stop: .seconds(3_600))
        let mics = play(hal, "mic")
        _ = try await self.start(studio!, ["t1", track], release: release)
        if start == .heldApp {
            await until(limit: busy, "the tap does not wait") { hal.calls.contains("lookUpApp \(Self.zoom)") }
        }
        weak let writer = studio!.writer(uid)
        try await Task.sleep(for: .seconds(1))

        let (error, took) = await stop(studio!, release: release)
        await mics.wait()
        #expect(error == nil)
        #expect(took < .seconds(2), "the stop returned after \(took)")
        #expect(studio!.lastTake?.gaps[track] == .deviceLost)
        #expect(!clipFrames(studio!, "t1").isEmpty, "no clip of t1")
        #expect(clipFrames(studio!, track).isEmpty)

        release()
        await until(limit: busy, "the writer that never attached did not go") { writer == nil }
        #expect(hal.watchers.count == 0, "a device-list watcher stays")
        #expect(hal.current(uid) == nil, "the late attach did not tear down")
        #expect(try captureStems().filter { $0.hasPrefix("take1-2-") }.isEmpty, "a segment of the late track")
        // The device comes back: a second take records on it.
        hal.failAttach { _, _ in nil }
        let late = play(hal, uid)
        try await studio!.startRecording(armed: [track], playhead: nil)
        await late.wait()
        try await studio!.stopRecording()
        #expect(!clipFrames(studio!, track).isEmpty, "the second take did not record")
        await studio!.settle()
        studio = nil
        let reopened = try await Studio.open(url)
        await reopened.settle()
    }
}
