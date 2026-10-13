import CoreAudio
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The silence warning of an app track (A9): the pure check by record host time, and one take
/// with synthetic zero records.
@MainActor
struct SilenceTests {
    /// The steps of a check fed one drain each 50 ms from 0 to `seconds`. A drain at or after
    /// `heardAt` has a sample that is not zero; the app has a process from `processFrom`; it
    /// plays when `playing` is true. Returns the host seconds of each warning and each rebuild.
    static func run(
        _ seconds: Double, heardAt: Double? = nil, processFrom: Double = 0, playing: Bool = true
    ) -> (warnings: [Double], rebuilds: [Double]) {
        var check = SilenceCheck()
        var warnings: [Double] = []
        var rebuilds: [Double] = []
        for step in 0...Int((seconds * 20).rounded()) {
            let time = Double(step) / 20
            let host = takeStart + UInt64((time * 1e9).rounded())
            check.take(
                firstHost: host, lastHost: host, heard: heardAt.map { time >= $0 } ?? false,
                hasProcess: time >= processFrom)
            let due = check.due(playing: { playing })
            if due.warn { warnings.append(time) }
            if due.rebuild { rebuilds.append(time) }
        }
        return (warnings, rebuilds)
    }

    /// 5.0 s of zeros while the app plays: one warning and a rebuild at 5.0 s.
    @Test func fiveSecondsOfZerosWithRunningOutputWarns() {
        #expect(Self.run(5).warnings == [5], "a warning at 5.0 s")
        #expect(Self.run(4.9).warnings.isEmpty, "no warning at 4.9 s")
    }

    /// A sample that is not zero at 4.0 s disarms the check, also after more zeros.
    @Test func aSoundBeforeTheLimitNeverWarns() {
        #expect(Self.run(60, heardAt: 4).warnings.isEmpty)
        #expect(Self.run(60, heardAt: 4).rebuilds.isEmpty)
    }

    /// Zeros while no matched process plays: no warning.
    @Test func zerosWithNoRunningOutputDoNotWarn() {
        #expect(Self.run(10, playing: false).warnings.isEmpty, "no warning")
    }

    /// The rebuilds at the warning, 10 s after it, and 40 s after it, then none (not at 105 s).
    /// One warning only.
    @Test func theRebuildsComeAt5And15And45Seconds() {
        let steps = Self.run(120)
        #expect(steps.warnings == [5], "one warning")
        #expect(steps.rebuilds == [5, 15, 45], "three rebuilds")
    }

    /// An app whose first process comes at 60 s: the check starts there, so the warning and the
    /// first rebuild come at 65 s.
    @Test func theCheckStartsAtTheFirstProcess() {
        let steps = Self.run(130, processFrom: 60)
        #expect(steps.warnings == [65], "the warning at 65 s")
        #expect(steps.rebuilds == [65, 75, 105])
    }

    /// A sound after the first rebuild stops the rebuilds.
    @Test func aSoundAfterARebuildStopsTheRebuilds() {
        let steps = Self.run(60, heardAt: 7)
        #expect(steps.rebuilds == [5], "no rebuild after the first sound")
    }

    /// A take: an app track with 6 s of zero records while the app plays shows `.noSound`, and
    /// the take result names it. Then a sound clears the state.
    @Test func aSilentAppTrackWarnsAndASoundClearsIt() async throws {
        let folder = try TemporaryFolder()
        let url = folder.url.appending(path: "Show.dirigible")
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Guest", layout: .mono)
        try session.setRoute(.app(bundleID: AppTakeTests.zoom), track: "t1")
        try session.write(to: url)
        let hal = TestHAL([])
        hal.setApp(AppTakeTests.zoom, AppTakeTests.found(), name: "zoom.us")
        let studio = try await Studio.open(url)
        studio.environment = .test(hal)
        try await studio.startRecording(armed: ["t1"], playhead: 0)

        let input = SyntheticInput(hal, AppTakeTests.zoomUID)
        var clock = DeviceClock()
        let zeros = clock.run(seconds: 6).map { record in
            var record = record
            record.buffers = [[Float](repeating: 0, count: record.frameCount)]
            return record
        }
        input.play(zeros, takeStartIn: url)
        await input.wait()
        await drained(hal, AppTakeTests.zoomUID, limit: .seconds(20))
        await until(limit: .seconds(3), "no warning") { studio.liveTracks["t1"]?.state == .noSound }
        await until(limit: .seconds(3), "no rebuild") { hal.inputs(AppTakeTests.zoomUID).count == 2 }
        input.play(clock.run(seconds: 0.2), takeStartIn: url)
        await input.wait()
        await drained(hal, AppTakeTests.zoomUID, limit: .seconds(20))
        await until(limit: .seconds(3), "the warning stays") { studio.liveTracks["t1"]?.state == .recording }
        try await studio.stopRecording()

        #expect(studio.lastTake?.silent == [:], "a sound came, so the track is not silent at the end")
    }

    /// A take that stays silent names the track and the app in the result, once.
    @Test func aTakeThatStaysSilentNamesTheTrack() async throws {
        let folder = try TemporaryFolder()
        let url = folder.url.appending(path: "Show.dirigible")
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Guest", layout: .mono)
        try session.setRoute(.app(bundleID: AppTakeTests.zoom), track: "t1")
        try session.write(to: url)
        let hal = TestHAL([])
        hal.setApp(AppTakeTests.zoom, AppTakeTests.found(), name: "zoom.us")
        let studio = try await Studio.open(url)
        studio.environment = .test(hal)
        try await studio.startRecording(armed: ["t1"], playhead: 0)

        let input = SyntheticInput(hal, AppTakeTests.zoomUID)
        var clock = DeviceClock()
        input.play(
            clock.run(seconds: 6).map { record in
                var record = record
                record.buffers = [[Float](repeating: 0, count: record.frameCount)]
                return record
            }, takeStartIn: url)
        await input.wait()
        await drained(hal, AppTakeTests.zoomUID, limit: .seconds(20))
        await until(limit: .seconds(3), "no warning") { studio.liveTracks["t1"]?.state == .noSound }
        try await studio.stopRecording()

        #expect(studio.lastTake?.silent == ["t1": "zoom.us"], "the silent track and its app")
    }
}
