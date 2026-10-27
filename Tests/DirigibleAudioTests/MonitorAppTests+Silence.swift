import CoreAudio
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The silence rule of an app monitor and the come back (C4, C4b): the zeros count from the
/// start of the current playing run, a new run rearms the warning, and
/// `rebuildSilentAppMonitors()` taps again a track that shows **No sound from**.
extension MonitorAppTests {
    /// Zoom runs and plays when `playing` is true.
    func setPlaying(_ hal: TestHAL, _ playing: Bool) {
        hal.setApp(Self.zoom, AppTakeTests.found(playing: playing), name: "zoom.us")
    }

    /// Sends `seconds` of zero records of `clock` into the current tap of Zoom, and returns after
    /// the writer took them: a barrier on its queue after the ring is empty.
    func feedZeros(_ hal: TestHAL, _ writer: DeviceWriter, _ clock: inout DeviceClock, seconds: Double) async {
        let input = SyntheticInput(hal, Self.zoomUID)
        input.play(
            clock.run(seconds: seconds).map { record in
                var record = record
                record.buffers = [[Float](repeating: 0, count: record.frameCount)]
                return record
            })
        await input.wait()
        await drained(hal, Self.zoomUID, limit: busy)
        await writer.started()
    }

    /// A monitor of Guest while Zoom does not play. Returns the studio, the writer, and a clock.
    func quietMonitor(_ hal: TestHAL) async throws -> (Studio, DeviceWriter, DeviceClock) {
        setPlaying(hal, false)
        let studio = try await studio(hal)
        try await studio.monitor(armed: ["guest"])
        return (studio, try #require(studio.monitorWriter(Self.zoomUID)), DeviceClock())
    }

    /// 60 s of zeros while Zoom does not play, then a playing run of zeros that warns.
    func warn(_ studio: Studio, _ hal: TestHAL, _ writer: DeviceWriter, _ clock: inout DeviceClock) async {
        await feedZeros(hal, writer, &clock, seconds: 60)
        setPlaying(hal, true)
        await feedZeros(hal, writer, &clock, seconds: 6.5)
        await until(limit: busy, "no warning after 6.5 s of a playing run") {
            studio.liveTracks["guest"]?.state == .noSound
        }
    }

    /// A monitor of Guest that shows the warning.
    func warnedMonitor(_ hal: TestHAL) async throws -> (Studio, DeviceWriter, DeviceClock) {
        let (studio, writer, start) = try await quietMonitor(hal)
        var clock = start
        await warn(studio, hal, writer, &clock)
        return (studio, writer, clock)
    }

    // MARK: C4

    @Test func aSilentMonitoredAppWarnsAfterFiveSecondsOfPlaying() async throws {
        let hal = hal()
        let (studio, writer, start) = try await quietMonitor(hal)
        var clock = start

        await feedZeros(hal, writer, &clock, seconds: 60)
        #expect(taps(hal) == 1, "zeros while Zoom does not play rebuild the tap")
        #expect(studio.liveTracks["guest"]?.state == .monitoring)
        setPlaying(hal, true)
        await feedZeros(hal, writer, &clock, seconds: 4.95)
        #expect(taps(hal) == 1, "a warning before 5 s of the playing run: \(hal.calls.suffix(4))")
        #expect(studio.liveTracks["guest"]?.state == .monitoring)
        await feedZeros(hal, writer, &clock, seconds: 1.5)
        await until(limit: busy, "no warning after 6.45 s of the playing run") {
            studio.liveTracks["guest"]?.state == .noSound
        }
        #expect(taps(hal) == 2, "the warning rebuilds the tap once")

        SyntheticInput(hal, Self.zoomUID).play(clock.run(seconds: 0.5))
        await until(limit: busy, "a sound does not clear the warning") {
            studio.liveTracks["guest"]?.state == .monitoring
        }
        await studio.settle()
        _ = folder
    }

    // MARK: C4b (a)

    @Test func aNewPlayingRunRearmsTheWarning() async throws {
        let hal = hal()
        let (studio, writer, start) = try await warnedMonitor(hal)
        var clock = start

        setPlaying(hal, false)
        await feedZeros(hal, writer, &clock, seconds: 2)
        #expect(studio.liveTracks["guest"]?.state == .noSound, "the warning goes while Zoom does not play")
        setPlaying(hal, true)
        await feedZeros(hal, writer, &clock, seconds: 1.5)
        await until(limit: busy, "a new playing run does not rearm") {
            studio.liveTracks["guest"]?.state == .monitoring
        }
        await feedZeros(hal, writer, &clock, seconds: 5)
        await until(limit: busy, "no warning in the new playing run") {
            studio.liveTracks["guest"]?.state == .noSound
        }
        await studio.settle()
        _ = folder
    }

    // MARK: C4b (b)

    @Test func aSilentAppMonitorRetapsWhenCalled() async throws {
        let hal = hal()
        let (studio, writer, start) = try await quietMonitor(hal)
        var clock = start
        await until(limit: busy, "no first tap") { taps(hal) == 1 }
        studio.rebuildSilentAppMonitors()
        await writer.started()
        #expect(taps(hal) == 1, "a monitor with no warning gets a new tap")

        await warn(studio, hal, writer, &clock)
        let before = taps(hal)
        studio.rebuildSilentAppMonitors()
        await until(limit: busy, "the come back makes no tap") { taps(hal) == before + 1 }
        await until(limit: busy, "the come back does not clear the warning") {
            studio.liveTracks["guest"]?.state == .monitoring
        }
        await playTone(hal)
        await until(limit: busy, "no app peak after the come back") { abs(peak(studio, "guest") - 0.5) <= 0.01 }
        await studio.settle()
        _ = folder
    }

    // MARK: C4b (d)

    @Test func aDeniedAppMonitorKeepsItsRebuildBudget() async throws {
        let hal = hal()
        let logs = folder.url.appending(path: "logs")
        let log = startLog(in: logs)
        setPlaying(hal, false)
        let studio = try await studio(hal)
        studio.environment.log = log
        try await studio.monitor(armed: ["guest"])
        let writer = try #require(studio.monitorWriter(Self.zoomUID))
        var clock = DeviceClock()

        for cycle in 1...70 {
            setPlaying(hal, false)
            await feedZeros(hal, writer, &clock, seconds: 1)
            setPlaying(hal, true)
            await feedZeros(hal, writer, &clock, seconds: 6.5)
            await until(limit: busy, "no warning in cycle \(cycle)") { studio.liveTracks["guest"]?.state == .noSound }
            studio.rebuildSilentAppMonitors()
            await writer.started()
        }

        #expect(taps(hal) - 1 == 11, "3 silence rebuilds and 8 come backs, not \(taps(hal) - 1)")
        let causes = TakeLogTests.lines(log, in: logs).map {
            $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        }
        .filter { $0.count >= 6 && $0[4] == "tap" && $0[5] == "rebuild" }
        .map { fieldValues($0)["cause"] }
        #expect(causes.count { $0 == "active" } == 8, "\(causes)")
        await until(limit: busy, "the warning does not stay") { studio.liveTracks["guest"]?.state == .noSound }
        await studio.settle()
        _ = folder
    }

    // MARK: C4b (e)

    @Test func aFinishedMonitorWriterDoesNotRetap() async throws {
        let hal = hal()
        let (studio, writer, _) = try await warnedMonitor(hal)
        let before = taps(hal)

        await writer.finish()
        studio.rebuildSilentAppMonitors()
        await writer.started()

        #expect(taps(hal) == before, "a finished writer taps again")
        await studio.settle()
        _ = folder
    }
}
