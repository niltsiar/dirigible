import CoreAudio
import DirigibleCore
import Foundation
import Testing
import os

@testable import DirigibleAudio

/// Input Levels meters an armed app track (decisions 0015 and 0029): a monitor writer with an app
/// tap. The test HAL gives the tap synthetic records; no test makes a real tap or reads the grant.
/// A held attach of the app is the System Audio Recording prompt: it blocks the IOProc create
/// (probe P1 leg H).
@MainActor
struct MonitorAppTests {
    static let zoom = "us.zoom.xos"
    static let zoomUID = "app:us.zoom.xos"
    /// The limit of a wait for work on the main actor (see `MonitorTests.busy`).
    let busy = Duration.seconds(20)
    let folder: TemporaryFolder
    let url: URL
    let mic = InputDevice(
        uid: "mic", name: "USB Mic", nominalRate: 48_000, availableRates: [48_000...48_000], channelsPerBuffer: [1],
        latency: 0)!

    /// `host` on channel 1 of `mic`, and `guest` (mono) on Zoom.
    init() throws {
        folder = try TemporaryFolder()
        url = folder.url.appending(path: "Show.dirigible")
        var session = Session(sampleRate: 48_000)
        try session.addTrack("host", name: "Host", layout: .mono)
        try session.addTrack("guest", name: "Guest", layout: .mono)
        try session.setRoute(.device(uid: "mic", channels: .mono(1)), track: "host")
        try session.setRoute(.app(bundleID: Self.zoom), track: "guest")
        try session.write(to: url)
    }

    /// Zoom runs with `processes`; an empty list is an app that does not run.
    func hal(processes: [AudioObjectID] = [41]) -> TestHAL {
        let hal = TestHAL([mic])
        hal.setApp(Self.zoom, AppTakeTests.found(processes: processes), name: "zoom.us")
        return hal
    }

    func studio(_ hal: TestHAL) async throws -> Studio {
        let studio = try await Studio.open(url)
        studio.environment = .test(hal)
        return studio
    }

    /// The tap creates of Zoom.
    func taps(_ hal: TestHAL) -> Int { hal.calls.count { $0 == "makeTap \(Self.zoomUID)" } }

    /// The taps of Zoom that no teardown destroyed.
    func liveTaps(_ hal: TestHAL) -> Int { taps(hal) - hal.calls.count { $0 == "destroyTap \(Self.zoomUID)" } }

    func peak(_ studio: Studio, _ track: TrackID) -> Float { studio.liveTracks[track]?.peak ?? 0 }

    /// Sends the tone of peak 0.5 into the current tap of Zoom, at real-time pace.
    func playTone(_ hal: TestHAL) async {
        SyntheticInput(hal, Self.zoomUID).play(await appToneRecords(), pace: .realTime)
    }

    // MARK: C1

    @Test func anArmedAppTrackGetsAMeter() async throws {
        let hal = hal()
        let studio = try await studio(hal)

        try await studio.monitor(armed: ["guest"])
        let writer = try #require(studio.monitorWriter(Self.zoomUID), "no monitor writer for the app")
        #expect(writer.app == Self.zoom)
        await playTone(hal)
        await until(limit: busy, "no app peak") { abs(peak(studio, "guest") - 0.5) <= 0.01 }

        #expect(studio.liveTracks["guest"]?.state == .monitoring)
        #expect(taps(hal) == 1)
        await studio.settle()
        _ = folder
    }

    // MARK: C2

    @Test func anAppTrackOutsideTheRequestHasNoTap() async throws {
        let hal = hal()
        let studio = try await studio(hal)

        try await studio.monitor(armed: [])
        try await studio.monitor(armed: ["host"])
        await until(limit: busy, "no monitor attach of mic") { hal.current("mic") != nil }
        #expect(studio.monitorWriter(Self.zoomUID) == nil)
        #expect(studio.liveTracks["guest"] == nil)
        #expect(taps(hal) == 0)

        // The control: the same track in the request gets a tap.
        try await studio.monitor(armed: ["guest"])
        await until(limit: busy, "no tap of the armed app track") { taps(hal) == 1 }
        await studio.settle()
        _ = folder
    }

    // MARK: C3

    @Test func aMonitoredAppThatDoesNotRunWaits() async throws {
        let hal = hal(processes: [])
        let studio = try await studio(hal)

        try await studio.monitor(armed: ["guest"])
        await until(limit: busy, "the app that does not run is not waited for") {
            studio.liveTracks["guest"]?.state == .waitingForApp
        }
        hal.setApp(Self.zoom, AppTakeTests.found())
        let writer = try #require(studio.monitorWriter(Self.zoomUID))
        writer.post(.devicesChanged, from: nil)
        await until(limit: busy, "the app start does not meter") { studio.liveTracks["guest"]?.state == .monitoring }

        #expect(taps(hal) == 2, "the app start rebuilds the tap")
        await studio.settle()
        _ = folder
    }

    // MARK: C5

    @Test func aMonitorAtThePromptDoesNotHoldTheCall() async throws {
        let hal = hal()
        hal.holdAttach(Self.zoomUID)
        defer { hal.releaseAttach(Self.zoomUID) }
        let studio = try await studio(hal)

        let returned = Done()
        let call = Task { @MainActor in
            try await studio.monitor(armed: ["guest"])
            returned.value = true
        }
        await until(limit: busy, "the monitor call waits for the prompt") { returned.value }
        await until(limit: busy, "the app attach is not at the prompt") { hal.heldAttachCount(Self.zoomUID) == 1 }
        #expect(studio.liveTracks["guest"]?.state == .monitoring)
        #expect(peak(studio, "guest") == 0)
        hal.releaseAttach(Self.zoomUID)
        try await call.value
        await playTone(hal)
        await until(limit: busy, "no app peak after the answer") { abs(peak(studio, "guest") - 0.5) <= 0.01 }
        await studio.settle()
        _ = folder
    }

    // MARK: C6

    @Test func anAppOnlyMonitorReadsNoMicrophone() async throws {
        let hal = hal()
        let studio = try await studio(hal)
        let reads = OSAllocatedUnfairLock(initialState: 0)
        studio.environment.microphoneAccess = {
            reads.withLock { $0 += 1 }
            return .denied
        }

        await #expect(throws: StudioError.microphoneAccess(.denied)) {
            try await studio.monitor(armed: ["guest", "host"])
        }
        #expect(reads.withLock { $0 } == 1)
        #expect(studio.monitors.isEmpty)
        #expect(studio.liveTracks.isEmpty)
        #expect(taps(hal) == 0)

        try await studio.monitor(armed: ["guest"])
        #expect(reads.withLock { $0 } == 1, "an app-only request reads the microphone")
        #expect(studio.monitorWriter(Self.zoomUID) != nil)
        await studio.settle()
        _ = folder
    }

    // MARK: C7

    @Test func aMonitorAtThePromptLeavesOneTap() async throws {
        let hal = hal()
        hal.holdAttach(Self.zoomUID)
        defer { hal.releaseAttach(Self.zoomUID) }
        let studio = try await studio(hal)
        studio.environment.stopLimit = .seconds(1)

        try await studio.monitor(armed: ["guest"])
        await until(limit: busy, "the app attach is not at the prompt") { hal.heldAttachCount(Self.zoomUID) == 1 }
        let first = try #require(studio.monitorWriter(Self.zoomUID))
        let watch = Stopwatch()
        try await studio.monitor(armed: [])
        #expect(watch.elapsed < .seconds(5), "Input Levels off waits for the prompt (wall \(watch.wall))")
        #expect(studio.liveTracks["guest"] == nil)
        try await studio.monitor(armed: ["guest"])
        await until(limit: busy, "the second app attach is not at the prompt") {
            hal.heldAttachCount(Self.zoomUID) == 2
        }
        hal.releaseAttach(Self.zoomUID)
        await first.finish()
        await until(limit: busy, "the second tap does not attach") { hal.inputs(Self.zoomUID).count == 2 }

        #expect(liveTaps(hal) == 1, "\(hal.calls)")
        #expect(studio.liveTracks["guest"]?.state == .monitoring)
        await studio.settle()
        _ = folder
    }

    // MARK: C8

    @Test func theMonitorTapsTheAppAfterTheMicrophone() async throws {
        let hal = hal()
        hal.delayAttach("mic", by: .milliseconds(300))
        let studio = try await studio(hal)

        try await studio.monitor(armed: ["host", "guest"])
        await until(limit: busy, "no tap of the app") { taps(hal) == 1 }

        let calls = hal.calls
        let micAttach = try #require(calls.firstIndex(of: "attach mic"), "\(calls)")
        let tap = try #require(calls.firstIndex(of: "makeTap \(Self.zoomUID)"))
        #expect(micAttach < tap, "the microphone attaches before the tap: \(calls)")
        await studio.settle()
        _ = folder
    }

    /// A microphone attach that does not end holds the tap only until the start deadline, and
    /// the monitor call does not wait for it.
    @Test func aHeldMicrophoneHoldsTheAppTapUntilTheStartLimit() async throws {
        let hal = hal()
        hal.holdAttach("mic")
        defer { hal.releaseAttach("mic") }
        let studio = try await studio(hal)
        studio.environment.startLimit = .seconds(1)

        let called = ContinuousClock.now
        let returned = Done()
        let call = Task { @MainActor in
            try await studio.monitor(armed: ["host", "guest"])
            returned.value = true
        }
        await until(limit: busy, "the monitor call waits for the microphone") { returned.value }
        await until(limit: busy, "no tap after the start limit") { taps(hal) == 1 }

        #expect(ContinuousClock.now - called >= .seconds(1), "the tap does not wait for the microphone")
        #expect(hal.heldAttachCount("mic") == 1)
        #expect(!hal.calls.contains("attach mic"), "the microphone attach ended before the tap")
        hal.releaseAttach("mic")
        try await call.value
        await studio.settle()
        _ = folder
    }
}

/// 30 s of a 1 kHz sine of amplitude 0.5, mono: longer than each wait of these tests. A global
/// is made once.
private let appTone: [InputRecord] = records(
    [sine(seconds: 30, rate: 48_000)], layout: [1], rate: 48_000, frames: 480)

/// The tone, made off the main actor, so it does not hold the main-actor tests.
@concurrent nonisolated func appToneRecords() async -> [InputRecord] { appTone }
