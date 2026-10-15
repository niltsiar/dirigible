import CoreAudio
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The tap capture path of an app source (A5, A6, A13, A14, W4, probe P13): a take with the
/// test HAL, whose app lookup gives a tap aggregate with synthetic records. No test makes a real
/// tap, reads the real grant, or plays app audio.
@MainActor
struct AppTakeTests {
    static let zoom = "us.zoom.xos"
    static let zoomUID = "app:us.zoom.xos"
    let folder: TemporaryFolder
    let url: URL
    let log = ReportLog()
    let mic = InputDevice(
        uid: "mic", name: "USB Mic", nominalRate: 48_000, availableRates: [48_000...48_000], channelsPerBuffer: [1],
        latency: 0)!

    /// `t1` Host on channel 1 of `mic`, `t2` Guest (mono) on Zoom, and `t3` (mono) with no route.
    init() throws {
        folder = try TemporaryFolder()
        url = folder.url.appending(path: "Show.dirigible")
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.addTrack("t2", name: "Guest", layout: .mono)
        try session.addTrack("t3", name: "Other", layout: .mono)
        try session.setRoute(.device(uid: "mic", channels: .mono(1)), track: "t1")
        try session.setRoute(.app(bundleID: Self.zoom), track: "t2")
        try session.write(to: url)
    }

    /// What the app lookup finds: process objects, the output UID, and the aggregate facts.
    static func found(
        processes: [AudioObjectID] = [41], rate: Double = 48_000, latency: Int = 0, channels: Int = 1,
        playing: Bool = true
    ) -> AppFound {
        AppFound(
            key: AppKey(processes: processes, output: "BuiltInSpeakerDevice"), output: "BuiltInSpeakerDevice",
            device: InputDevice(
                uid: zoomUID, name: zoom, nominalRate: rate, availableRates: [rate...rate],
                channelsPerBuffer: [channels], latency: latency)!,
            playing: playing)
    }

    func hal(_ devices: [InputDevice]? = nil) -> TestHAL {
        let hal = TestHAL(devices ?? [mic])
        hal.setApp(Self.zoom, Self.found(), name: "zoom.us")
        return hal
    }

    func studio(_ hal: TestHAL, access: MicrophoneAccess? = nil, tapsAvailable: Bool = true) async throws -> Studio {
        let studio = try await Studio.open(url)
        studio.environment = .test(hal, access: access)
        studio.environment.tapsAvailable = tapsAvailable
        return studio
    }

    /// Waits until the host clock is `seconds` past the saved take start. Synthetic records in a
    /// burst run ahead of the clock, and a stop ends the take at the host time of the stop (E1).
    func passTakeTime(_ studio: Studio, seconds: Double) async throws {
        let start = try #require(studio.session.recording?.takeStartHostTimeNanos)
        let end = start &+ UInt64(seconds * 1e9)
        while hostNanosNow() < end { try await Task.sleep(for: .milliseconds(20)) }
    }

    func clips(_ studio: Studio, _ track: TrackID) -> [Clip] {
        studio.session.track(track).map { Array($0.clips) } ?? []
    }

    /// An app writer of arm 1 (mono), as `Studio.begin` makes it. The watchdog limits are long, so
    /// a busy suite gets no second attach before a check of the first.
    func appWriter(_ hal: TestHAL) -> DeviceWriter {
        let url = folder.url
        let device = InputDevice(
            uid: Self.zoomUID, name: "zoom.us", nominalRate: 48_000, availableRates: [48_000...48_000],
            channelsPerBuffer: [1], latency: 0)!
        let writer = DeviceWriter(
            device: device, tracks: [(arm: 1, channels: .mono(1))], files: TakeFiles(take: 1, folder: { url }),
            hal: hal.hal, report: log.closure, silenceLimit: noWatchdog, firstRecordLimit: noWatchdog,
            app: Self.zoom)
        writer.start()
        return writer
    }

    /// A5: the take places one clip on the app track, and its capture has the app UID and name.
    /// Each device attaches before the tap: the attach of `mic` is slow here.
    @Test func aTakePlacesAClipWithTheAppUID() async throws {
        let hal = hal()
        hal.delayAttach("mic", by: .milliseconds(300))
        let studio = try await studio(hal)
        try await studio.startRecording(armed: ["t1", "t2"], playhead: 0)
        let micInput = SyntheticInput(hal, "mic")
        let appInput = SyntheticInput(hal, Self.zoomUID)
        var micClock = DeviceClock()
        var appClock = DeviceClock()
        micInput.play(micClock.run(seconds: 0.5), takeStartIn: url)
        appInput.play(appClock.run(seconds: 0.5), takeStartIn: url)
        await micInput.wait()
        await appInput.wait()
        try await passTakeTime(studio, seconds: 0.6)
        try await studio.stopRecording()

        let clip = try #require(clips(studio, "t2").first, "a clip on the app track")
        #expect(clips(studio, "t2").count == 1)
        let file = try #require(studio.session.files[clip.file])
        let capture = try #require(file.capture.flatMap { studio.session.captures[$0] })
        #expect(capture.deviceUID == "app:us.zoom.xos", "the app UID")
        #expect(capture.deviceName == "zoom.us", "the app name")
        #expect(abs(clip.length.count - 24_000) <= 1)
        let calls = hal.calls
        let micAttach = try #require(calls.firstIndex(of: "attach mic"))
        let tap = try #require(calls.firstIndex(of: "makeTap app:us.zoom.xos"))
        #expect(micAttach < tap, "each device attaches before the tap: \(calls)")
    }

    /// Code gate E1: an app attach that waits (the System Audio Recording prompt) never delays the
    /// device writers or the take control. The start returns, the disk watch ticks, and the stop
    /// ends the device clip at the stop time; the release then ends the stop.
    @Test func aWaitingAppAttachDelaysNoDeviceTrack() async throws {
        let hal = hal()
        hal.holdTaps()
        defer { hal.releaseTaps() }
        let studio = try await studio(hal)
        let started = Done()
        let start = Task { @MainActor in
            try await studio.startRecording(armed: ["t1", "t2"], playhead: 0)
            started.value = true
        }
        // A start that waits for the held tap fails this wait; the release then lets it end.
        await until(limit: .seconds(20), "the start waits for the app") { started.value }
        if !started.value { hal.releaseTaps() }
        try await start.value
        let micInput = SyntheticInput(hal, "mic")
        var micClock = DeviceClock()
        micInput.play(micClock.run(seconds: 3), pace: .realTime, takeStartIn: url)
        await until(limit: .seconds(20), "the disk watch did not tick") { studio.recordTimeLeft != nil }
        try await Task.sleep(for: .milliseconds(500))
        let takeStart = try #require(studio.session.recording?.takeStartHostTimeNanos)
        // The stop host is read in the job of the stop, so a main-actor hold before it does not
        // count as time after the stop.
        let stop = Task {
            let host = hostNanosNow()
            try await studio.stopRecording()
            return host
        }
        // Code gate round 2 F1: the device writer closes while the app writer waits.
        await until(limit: .seconds(10), "the mic did not detach while the app waits") {
            hal.calls.contains("detach mic")
        }
        #expect(!hal.calls.contains("makeTap \(Self.zoomUID)"), "the tap was held until the release")
        hal.releaseTaps()
        let stopHost = try await stop.value
        await micInput.wait()
        #expect(hal.calls.contains("detach app:us.zoom.xos"), "the app writer finished")

        let length = try #require(clips(studio, "t1").first?.length.count)
        let expected = Int((Double(stopHost &- takeStart) / 1e9 * 48_000).rounded())
        // The records lag the take start (the attach and the producer start), so the clip can be
        // shorter; it never goes past the stop.
        #expect(length > 0 && length <= expected + 12_000, "the device clip ends at the stop: \(length), \(expected)")
    }

    /// Code gate E1: the stop sets the end of the take on each writer first, so a device whose
    /// finish waits (a held detach) writes no record after the stop.
    @Test func aStopEndsADeviceClipWhileItsDetachWaits() async throws {
        let hal = hal()
        let studio = try await studio(hal)
        try await studio.startRecording(armed: ["t1"], playhead: 0)
        let micInput = SyntheticInput(hal, "mic")
        var micClock = DeviceClock()
        // Longer than any delay of a loaded suite: the detach at the stop ends the sends. The wait
        // reads the segment file, which stays; a ring that the drain empties does not.
        micInput.play(micClock.run(seconds: 60), pace: .realTime, takeStartIn: url)
        let segment = url.appending(path: "Capture/take1-1-1.caf").path
        await until(limit: .seconds(30), "no record") { FileManager.default.fileExists(atPath: segment) }
        try await Task.sleep(for: .milliseconds(500))
        let gate = Gate(limit: Gate.openLimit)
        hal.holdNextDetach(in: gate)
        let takeStart = try #require(studio.session.recording?.takeStartHostTimeNanos)
        // The stop host is read in the job of the stop, so a main-actor hold before it does not
        // count as time after the stop.
        let stop = Task {
            let host = hostNanosNow()
            try await studio.stopRecording()
            return host
        }
        try await Task.sleep(for: .milliseconds(1500))
        gate.open()
        let stopHost = try await stop.value
        await micInput.wait()

        let length = try #require(clips(studio, "t1").first?.length.count)
        let expected = Int((Double(stopHost &- takeStart) / 1e9 * 48_000).rounded())
        #expect(length > 0 && length <= expected + 12_000, "no record after the stop: \(length), \(expected)")
    }

    /// A5 (0006): the aggregate of a tap is private, starts its IO at once (auto start false),
    /// has drift compensation, and has the output of the app as its main sub-device.
    @Test func theAggregateStartsItsIOAtOnce() {
        let description = aggregateDescription(output: "BuiltInSpeakerDevice", tapUID: "TAP", uid: "AGG")
        #expect(description[kAudioAggregateDeviceTapAutoStartKey] as? Bool == false, "auto start false")
        #expect(description[kAudioAggregateDeviceIsPrivateKey] as? Bool == true)
        #expect(description[kAudioAggregateDeviceMainSubDeviceKey] as? String == "BuiltInSpeakerDevice")
        #expect(description[kAudioAggregateDeviceUIDKey] as? String == "AGG")
        let taps = description[kAudioAggregateDeviceTapListKey] as? [[String: Any]]
        #expect(taps?.first?[kAudioSubTapUIDKey] as? String == "TAP")
        #expect(taps?.first?[kAudioSubTapDriftCompensationKey] as? Bool == true)
    }

    /// A6: the detach stops and destroys the IOProc, then destroys the aggregate, then the tap.
    /// Each step runs when an earlier step fails.
    @Test(arguments: [nil, "detach", "aggregate", "tap"])
    func theDetachTearsDownTheTapInOrder(failing: String?) async throws {
        let hal = hal()
        hal.failTeardown(failing)
        let writer = appWriter(hal)
        await until("no first attach") { hal.inputs(Self.zoomUID).count == 1 }
        await writer.finish()

        #expect(
            Array(hal.calls.suffix(3)) == [
                "detach app:us.zoom.xos", "destroyAggregate app:us.zoom.xos", "destroyTap app:us.zoom.xos",
            ], "the teardown order")
    }

    /// A6: a detach is clean only when each step is clean. Each failed step keeps the ring, and
    /// after 8 the app stays lost (0013). Control: clean steps give an attach for each back.
    @Test(arguments: [nil, "detach", "aggregate", "tap"])
    func eachFailedTeardownStepCountsTowardTheLimit(failing: String?) async throws {
        let hal = hal()
        hal.failTeardown(failing)
        let writer = appWriter(hal)
        await until("no first attach") { hal.inputs(Self.zoomUID).count == 1 }

        for cycle in 1...10 {
            writer.post(.alive(false), from: hal.inputs(Self.zoomUID).last)
            writer.post(.devicesChanged, from: nil)
            let expected = failing == nil ? cycle + 1 : min(cycle + 1, 8)
            await until("cycle \(cycle): no back") { hal.inputs(Self.zoomUID).count == expected }
        }
        await writer.finish()

        #expect(hal.inputs(Self.zoomUID).count == (failing == nil ? 11 : 8), "attaches up to the limit")
    }

    /// W4: a new appearance keeps the app UID and name, and takes the rate and the latency of
    /// the new aggregate.
    @Test func aNewAppearanceKeepsTheAppIdentity() async throws {
        let hal = hal()
        let writer = appWriter(hal)
        await until("no first attach") { hal.inputs(Self.zoomUID).count == 1 }
        let input = SyntheticInput(hal, Self.zoomUID)
        var clock = DeviceClock()
        input.play(clock.run(seconds: 0.2))
        await input.wait()
        hal.setApp(Self.zoom, Self.found(rate: 44_100, latency: 512))
        writer.post(.alive(false), from: hal.inputs(Self.zoomUID).last)
        writer.post(.devicesChanged, from: nil)
        await until("no second attach") { hal.inputs(Self.zoomUID).count == 2 }
        var slow = DeviceClock(headerRate: 44_100, realRate: 44_100)
        input.play(slow.run(seconds: 0.2))
        await input.wait()
        await writer.finish()

        let data = try Data(contentsOf: folder.url.appending(path: "take1-1-2.sidecar"))
        let header = try #require(try Sidecar.decode(data)?.header)
        #expect(header.deviceUID == "app:us.zoom.xos", "the app UID")
        #expect(header.deviceName == "zoom.us", "the app name")
        #expect(header.availableRates == [44_100...44_100], "the rate of the new aggregate")
        #expect(header.latency == 512, "the latency of the new aggregate")
    }

    /// Probe P13: the tap stream is the last input buffer of its aggregate, after the inputs of
    /// the main sub-device (a headset microphone here). The app track records the tap.
    @Test func anAppTrackRecordsTheLastBufferOfItsAggregate() async throws {
        let hal = hal()
        hal.setTapLayout(Self.zoomUID, [1, 1])
        let writer = appWriter(hal)
        await until("no first attach") { hal.inputs(Self.zoomUID).count == 1 }
        let input = SyntheticInput(hal, Self.zoomUID)
        var clock = DeviceClock()
        input.play(
            clock.run(seconds: 0.2).map { record in
                var record = record
                record.buffers = [
                    [Float](repeating: 0.5, count: record.frameCount),
                    [Float](repeating: 0.25, count: record.frameCount),
                ]
                return record
            })
        await input.wait()
        await writer.finish()

        let samples = try readAudio(folder.url.appending(path: "take1-1-1.caf")).samples
        #expect(!samples.isEmpty && samples.allSatisfy { $0 == 0.25 }, "the tap samples, not the microphone")
    }

    /// Decision 0029: one track for each app.
    @Test func aSecondTrackOnTheSameAppIsRefused() async throws {
        let studio = try await studio(hal())
        try studio.edit(ripple: false) { session throws(SessionError) in
            try session.setRoute(.app(bundleID: Self.zoom), track: "t3")
        }
        await #expect(throws: StudioError.channelInUse("t2", "t3")) {
            try await studio.startRecording(armed: ["t2", "t3"], playhead: 0)
        }
    }

    /// A13: a take whose armed tracks are all app tracks does not read the microphone access.
    /// A take with a device track still refuses with no access.
    @Test(arguments: [false, true])
    func anAppOnlyTakeNeedsNoMicrophoneAccess(withDevice: Bool) async throws {
        let studio = try await studio(hal(), access: .denied)
        guard withDevice else {
            try await studio.startRecording(armed: ["t2"], playhead: 0)
            #expect(studio.transport == .recording(take: 1), "an app-only take starts")
            try await studio.stopRecording()
            return
        }
        await #expect(throws: StudioError.microphoneAccess(.denied)) {
            try await studio.startRecording(armed: ["t1", "t2"], playhead: 0)
        }
    }

    /// A14: with no process taps (macOS 14.0 and 14.1), a take with an app track throws a named
    /// error before any lookup and changes nothing. Control: a device take starts.
    @Test func aTakeWithAnAppNeedsProcessTaps() async throws {
        let hal = hal()
        let studio = try await studio(hal, tapsAvailable: false)
        let before = try Data(contentsOf: url.appending(path: "session.xml"))
        await #expect(throws: StudioError.appSourcesUnavailable) {
            try await studio.startRecording(armed: ["t1", "t2"], playhead: 0)
        }
        #expect(hal.calls.isEmpty, "no lookup")
        #expect(try Data(contentsOf: url.appending(path: "session.xml")) == before)

        try await studio.startRecording(armed: ["t1"], playhead: 0)
        #expect(studio.transport == .recording(take: 1), "control: a device take starts")
        try await studio.stopRecording()
    }

    /// Fix check 6: a take with a length ends the app clip at the same host time as the device
    /// clip.
    @Test func aTakeWithALengthEndsTheAppClipToo() async throws {
        let hal = hal()
        let studio = try await studio(hal)
        _ = try await studio.beginRecording(armed: ["t1", "t2"], playhead: 0, length: 300_000_000)
        let micInput = SyntheticInput(hal, "mic")
        let appInput = SyntheticInput(hal, Self.zoomUID)
        var micClock = DeviceClock()
        var appClock = DeviceClock()
        micInput.play(micClock.run(seconds: 0.5), takeStartIn: url)
        appInput.play(appClock.run(seconds: 0.5), takeStartIn: url)
        await micInput.wait()
        await appInput.wait()
        try await passTakeTime(studio, seconds: 0.6)
        try await studio.stopRecording()

        let host = try #require(clips(studio, "t1").first?.length.count)
        let guest = try #require(clips(studio, "t2").first?.length.count)
        #expect(abs(guest - 14_400) <= 1 && abs(host - 14_400) <= 1, "both clips end at 0.3 s: \(host), \(guest)")
    }
}

/// A flag that a main-actor task sets.
@MainActor final class Done {
    var value = false
}
