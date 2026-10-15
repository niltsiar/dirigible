import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The input monitor of decision 0015: a device writer with no take meters the armed tracks and
/// writes no file. Each test has its control.
@MainActor
struct MonitorTests {
    /// The limit of a wait for work on the main actor. In a full suite, the `@MainActor` suites
    /// hold it for seconds (see `Gate`). It is less than one suite run, and each producer and
    /// held attach of these tests runs longer.
    let busy = Duration.seconds(20)
    let duo = InputDevice(
        uid: "duo", name: "Duo", nominalRate: 48_000, availableRates: [48_000...48_000], channelsPerBuffer: [2],
        latency: 0)!

    /// A package with `t1` on channel 1 of `duo`, `t2` on channel 2, and `t3` with no route. The
    /// file work runs off the main actor (the tdd skill).
    func package() async throws -> (folder: TemporaryFolder, url: URL) {
        let folder = try TemporaryFolder()
        let url = folder.url.appending(path: "Show.dirigible")
        try await offMainActor {
            var session = Session(sampleRate: 48_000)
            try session.addTrack("t1", name: "Host", layout: .mono)
            try session.addTrack("t2", name: "Guest", layout: .mono)
            try session.addTrack("t3", name: "Music", layout: .mono)
            try session.setRoute(Route.device(uid: "duo", channels: .mono(1)), track: "t1")
            try session.setRoute(Route.device(uid: "duo", channels: .mono(2)), track: "t2")
            try session.write(to: url)
        }
        return (folder, url)
    }

    func open(_ url: URL, _ hal: TestHAL, access: MicrophoneAccess? = nil) async throws -> Studio {
        let studio = try await Studio.open(url)
        studio.environment = .test(hal, access: access)
        return studio
    }

    /// The recursive file list of the package and the bytes of `session.xml`.
    func files(_ url: URL) async throws -> (paths: [String], session: Data) {
        let result = LockedBox<([String], Data)>()
        try await offMainActor {
            let paths = FileManager.default.enumerator(atPath: url.path)?.compactMap { $0 as? String } ?? []
            result.value = (paths.sorted(), try Data(contentsOf: url.appending(path: "session.xml")))
        }
        let (paths, session) = try #require(result.value)
        return (paths, session)
    }

    func peak(_ studio: Studio, _ track: TrackID) -> Float { studio.liveTracks[track]?.peak ?? 0 }

    // MARK: Criterion 1

    @Test func theMonitorMetersEachTrackAndWritesNoFile() async throws {
        let (folder, url) = try await package()
        let hal = TestHAL([duo])
        let studio = try await open(url, hal)
        let before = try await files(url)

        try await studio.monitor(armed: ["t1", "t2"])
        SyntheticInput(hal, "duo").play(await toneRecords(), pace: .realTime)
        await until(limit: busy, "no monitor peak on t1") { abs(peak(studio, "t1") - 0.5) <= 0.01 }

        #expect(studio.liveTracks["t1"]?.state == .monitoring)
        // The control in the same poll: channel 2 is silent.
        #expect(studio.liveTracks["t2"]?.state == .monitoring)
        #expect(peak(studio, "t2") <= 1e-6)
        try await studio.monitor(armed: [])
        let after = try await files(url)
        #expect(after.paths == before.paths)
        #expect(after.session == before.session)
        await studio.settle()
        _ = folder
    }

    // MARK: Criterion 2

    @Test func noArmedTrackReleasesTheDevice() async throws {
        let (folder, url) = try await package()
        let hal = TestHAL([duo])
        let studio = try await open(url, hal)

        try await studio.monitor(armed: [])
        try await studio.monitor(armed: ["t3"])
        #expect(hal.tries("duo").isEmpty)
        #expect(studio.liveTracks.isEmpty)

        // The control: an armed routed track holds the device.
        try await studio.monitor(armed: ["t1"])
        await until(limit: busy, "no monitor attach") { hal.current("duo") != nil }

        try await studio.monitor(armed: [])
        #expect(hal.current("duo") == nil)
        #expect(studio.liveTracks.isEmpty)
        await studio.settle()
        _ = folder
    }

    /// Code gate round 1, item 2: a route change replaces the monitor writer of `duo`. A report
    /// with the number of the old writer changes nothing. Control: the same report with the
    /// number of the new writer.
    @Test func aReportOfAReplacedMonitorWriterChangesNothing() async throws {
        let (folder, url) = try await package()
        let hal = TestHAL([duo])
        let studio = try await open(url, hal)
        try await studio.monitor(armed: ["t1"])
        let old = try #require(studio.monitors["duo"]?.number)

        try studio.edit(ripple: false) { s throws(SessionError) in
            try s.setRoute(Route.device(uid: "duo", channels: .mono(2)), track: "t1")
        }
        try await studio.monitor(armed: ["t1"])
        let new = try #require(studio.monitors["duo"]?.number)
        #expect(new != old)

        let lost = Report.state(take: 0, arm: 1, .deviceLost, status: nil)
        studio.applyMonitor(lost, number: old, uid: "duo")
        #expect(studio.liveTracks["t1"]?.state == .monitoring)
        studio.applyMonitor(lost, number: new, uid: "duo")
        #expect(studio.liveTracks["t1"]?.state == .deviceLost)
        await studio.settle()
        _ = folder
    }

    // MARK: Criterion 3

    /// The test holds the first studio after its `settle()`, so only an explicit release can
    /// free the device. Then the reopen monitors at once.
    @Test func settleReleasesTheDeviceAndAReopenMonitorsAtOnce() async throws {
        let (folder, url) = try await package()
        let hal = TestHAL([duo])
        do {
            let studio = try await open(url, hal)
            try await studio.monitor(armed: ["t1"])
            await until(limit: busy, "no monitor attach") { hal.current("duo") != nil }
            await studio.settle()
            #expect(hal.current("duo") == nil)
            #expect(studio.liveTracks.isEmpty)
        }

        let studio = try await open(url, hal)
        try await studio.monitor(armed: ["t1"])
        await until(limit: busy, "no second attach") { hal.inputs("duo").count == 2 && hal.current("duo") != nil }
        SyntheticInput(hal, "duo").play(await toneRecords(), pace: .realTime)
        await until(limit: busy, "no peak after the reopen") { abs(peak(studio, "t1") - 0.5) <= 0.01 }
        await studio.settle()
        #expect(hal.current("duo") == nil)
        _ = folder
    }

    // MARK: Criterion 11

    @Test(arguments: [nil, .notDetermined, .denied] as [MicrophoneAccess?])
    func monitorNeedsMicrophoneAccess(access: MicrophoneAccess?) async throws {
        let (folder, url) = try await package()
        let hal = TestHAL([duo])
        let studio = try await open(url, hal, access: access)

        guard let access else {
            // The control: a granted access attaches.
            try await studio.monitor(armed: ["t1"])
            await until(limit: busy, "no monitor attach") { hal.current("duo") != nil }
            await studio.settle()
            return
        }
        await #expect(throws: StudioError.microphoneAccess(access)) { try await studio.monitor(armed: ["t1"]) }
        #expect(hal.tries("duo").isEmpty)
        #expect(studio.liveTracks.isEmpty)
        await studio.settle()
        _ = folder
    }

    // MARK: Criterion 9

    @Test func aMissingDeviceStartsLost() async throws {
        let (folder, url) = try await package()
        let hal = TestHAL([duo])
        hal.set("duo", id: nil)
        let studio = try await open(url, hal)

        try await studio.monitor(armed: ["t1"])
        await until(limit: busy, "t1 is not lost") { studio.liveTracks["t1"]?.state == .deviceLost }
        #expect(hal.tries("duo").isEmpty)

        hal.set("duo", id: 7)
        studio.monitorWriter("duo")?.post(.devicesChanged, from: nil)
        await until(limit: busy, "t1 did not come back") { studio.liveTracks["t1"]?.state == .monitoring }
        #expect(hal.current("duo") != nil)
        await studio.settle()
        _ = folder
    }

    // MARK: Criterion 19

    /// Control: the take attach after the monitor has the 10 s capacity.
    @Test func aMonitorRingHoldsOneSecond() async throws {
        let (folder, url) = try await package()
        let hal = TestHAL([duo])
        let studio = try await open(url, hal)

        try await studio.monitor(armed: ["t1"])
        await until(limit: busy, "no monitor attach") { hal.current("duo") != nil }
        #expect(hal.capacities("duo") == [524_288])
        #expect(CaptureRing.capacity(rate: 48_000, channels: 2, seconds: 1) == 524_288)

        try await studio.monitor(armed: [])
        try await studio.startRecording(armed: ["t1"], playhead: 0)
        await until(limit: busy, "no take attach") { hal.capacities("duo").count == 2 }
        #expect(hal.capacities("duo").last == 8_388_608)
        try await studio.stopRecording()
        _ = folder
    }

    // MARK: Criterion 20

    /// Control: a take holds the sleep assertion.
    @Test func aMonitorHoldsTheLatencyActivityOnly() async throws {
        let (folder, url) = try await package()
        let hal = TestHAL([duo])
        let studio = try await open(url, hal)

        try await studio.monitor(armed: ["t1"])
        #expect(studio.monitorActivity != nil)
        #expect(studio.sleepAssertion == nil)
        try await studio.monitor(armed: [])
        #expect(studio.monitorActivity == nil)

        try await studio.monitor(armed: ["t1"])
        #expect(studio.monitorActivity != nil)
        await studio.settle()
        #expect(studio.monitorActivity == nil)

        try await studio.startRecording(armed: ["t1"], playhead: 0)
        #expect(studio.sleepAssertion != nil)
        try await studio.stopRecording()
        _ = folder
    }
}

/// A value that a `@Sendable` closure sets and the test reads after it.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?

    var value: Value? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// 30 s of records of `duo` with a 1 kHz sine of amplitude 0.5 on channel 1 and silence on
/// channel 2. It runs longer than each wait of the monitor tests. A global is made once.
private let monitorTone: [InputRecord] = {
    let one = sine(seconds: 30, rate: 48_000)
    var samples = [Float](repeating: 0, count: one.count * 2)
    for (frame, value) in one.enumerated() { samples[frame * 2] = value }
    return records([samples], layout: [2], rate: 48_000, frames: 480)
}()

/// The tone, made off the main actor, so it does not hold the main-actor tests.
@concurrent nonisolated func toneRecords() async -> [InputRecord] { monitorTone }
