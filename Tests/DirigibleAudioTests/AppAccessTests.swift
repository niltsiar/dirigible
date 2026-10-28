import CoreAudio
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// **No access** on an app tap with no grant (decision 0006, probe P1): after each attach of a
/// monitor app writer, a throwaway tap of the same processes gets the set of its description.
/// `'!hog'` shows `.noAccess` until a sample that is not zero; noErr clears it; another status
/// changes nothing. A take writer runs no check. The test HAL gives the status of the check.
@MainActor
struct AppAccessTests {
    let monitor: MonitorAppTests

    init() throws { monitor = try MonitorAppTests() }

    var busy: Duration { monitor.busy }

    func state(_ studio: Studio) -> LiveTrack.State? { studio.liveTracks["guest"]?.state }

    /// The grant checks of Zoom.
    func checks(_ hal: TestHAL) -> Int { hal.calls.count { $0 == "tapAccess \(MonitorAppTests.zoomUID)" } }

    /// A monitor of Guest whose grant check gives `status`.
    func monitorWith(_ status: OSStatus) async throws -> (TestHAL, Studio, DeviceWriter) {
        let hal = monitor.hal()
        hal.setTapAccess(MonitorAppTests.zoom, status)
        let studio = try await monitor.studio(hal)
        try await studio.monitor(armed: ["guest"])
        let writer = try #require(studio.monitorWriter(MonitorAppTests.zoomUID))
        await until(limit: busy, "no first tap") { monitor.taps(hal) == 1 }
        await writer.started()
        return (hal, studio, writer)
    }

    @Test func aTapWithNoGrantShowsNoAccess() async throws {
        let (hal, studio, _) = try await monitorWith(kAudioDevicePermissionsError)

        await until(limit: busy, "no .noAccess after the first attach: \(String(describing: state(studio)))") {
            state(studio) == .noAccess
        }
        #expect(checks(hal) == 1)
        await studio.settle()
    }

    @Test func aGrantedTapShowsMonitoring() async throws {
        let (hal, studio, _) = try await monitorWith(noErr)

        await monitor.playTone(hal)
        await until(limit: busy, "no app peak") { abs(monitor.peak(studio, "guest") - 0.5) <= 0.01 }
        #expect(state(studio) == .monitoring)
        #expect(checks(hal) == 1)
        await studio.settle()
    }

    @Test func aSoundClearsNoAccess() async throws {
        let (hal, studio, _) = try await monitorWith(kAudioDevicePermissionsError)
        await until(limit: busy, "no .noAccess") { state(studio) == .noAccess }

        await monitor.playTone(hal)
        await until(limit: busy, "a sound does not clear .noAccess") {
            state(studio) == .monitoring && abs(monitor.peak(studio, "guest") - 0.5) <= 0.01
        }
        await studio.settle()
    }

    /// `'!hog'`, then a status that is neither noErr nor `'!hog'` at the silence rebuild: the
    /// track keeps `.noAccess` through 6.5 s of zeros while Zoom plays, and never shows `.noSound`.
    @Test func noAccessComesBeforeNoSound() async throws {
        let (hal, studio, writer) = try await monitorWith(kAudioDevicePermissionsError)
        await until(limit: busy, "no .noAccess") { state(studio) == .noAccess }
        hal.setTapAccess(MonitorAppTests.zoom, kAudioHardwareBadObjectError)
        var clock = DeviceClock()

        await monitor.feedZeros(hal, writer, &clock, seconds: 6.5)
        await until(limit: busy, "no silence rebuild after 6.5 s of zeros") { monitor.taps(hal) == 2 }
        await monitor.feedZeros(hal, writer, &clock, seconds: 1)

        #expect(state(studio) == .noAccess)
        #expect(checks(hal) == 2, "the rebuild runs the check again")
        await studio.settle()
    }

    /// The check makes no tap line and no teardown line: the counts equal those of a granted run.
    @Test func theAccessCheckLeavesTheRecordedTap() async throws {
        var counts: [OSStatus: (taps: Int, teardowns: Int)] = [:]
        for status in [noErr, kAudioDevicePermissionsError] {
            let (hal, studio, writer) = try await monitorWith(status)
            #expect(checks(hal) == 1, "one check after the first attach (status \(status))")
            var clock = DeviceClock()
            await monitor.feedZeros(hal, writer, &clock, seconds: 6.5)
            await until(limit: busy, "no silence rebuild (status \(status))") { monitor.taps(hal) == 2 }
            await writer.started()
            #expect(checks(hal) == 2, "one more check after the rebuild (status \(status))")
            counts[status] = (monitor.taps(hal), hal.calls.count { $0 == "destroyTap \(MonitorAppTests.zoomUID)" })
            await studio.settle()
        }
        #expect(counts[kAudioDevicePermissionsError]?.taps == counts[noErr]?.taps)
        #expect(counts[kAudioDevicePermissionsError]?.teardowns == counts[noErr]?.teardowns)
    }

    @Test func aTakeRunsNoAccessCheck() async throws {
        let hal = monitor.hal()
        hal.setTapAccess(MonitorAppTests.zoom, kAudioDevicePermissionsError)
        let studio = try await monitor.studio(hal)
        studio.environment.stopLimit = .seconds(5)

        try await studio.startRecording(armed: ["guest"], playhead: 0)
        let input = SyntheticInput(hal, MonitorAppTests.zoomUID)
        var clock = DeviceClock()
        input.play(
            clock.run(seconds: 0.5).map { record in
                var record = record
                record.buffers = [[Float](repeating: 0, count: record.frameCount)]
                return record
            }, takeStartIn: monitor.url)
        await input.wait()
        await drained(hal, MonitorAppTests.zoomUID, limit: busy)

        #expect(checks(hal) == 0, "\(hal.calls)")
        #expect(state(studio) == .recording)
        try await monitor.passTakeTime(studio, seconds: 0.6)
        try await studio.stopRecording()
        await studio.settle()
    }

    /// The come back after a grant in System Settings: a track that shows `.noAccess` gets a new
    /// tap, and a noErr check clears the state before any sound.
    @Test func aGrantClearsNoAccessAtTheComeBack() async throws {
        let (hal, studio, writer) = try await monitorWith(kAudioDevicePermissionsError)
        await until(limit: busy, "no .noAccess") { state(studio) == .noAccess }
        let before = monitor.taps(hal)

        hal.setTapAccess(MonitorAppTests.zoom, noErr)
        studio.rebuildSilentAppMonitors()
        await writer.started()
        #expect(monitor.taps(hal) == before + 1, "the come back makes no tap: \(hal.calls.suffix(4))")
        await until(limit: busy, "the grant does not clear .noAccess") { state(studio) == .monitoring }

        await monitor.playTone(hal)
        await until(limit: busy, "no app peak after the come back") { abs(monitor.peak(studio, "guest") - 0.5) <= 0.01 }
        await studio.settle()
    }
}
