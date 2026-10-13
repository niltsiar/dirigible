import CoreAudio
import DirigibleCore
import Foundation
import Observation
import Testing

@testable import DirigibleAudio

/// The meter feed of decision 0014 (record-ui criteria 4, 5, and 6): the drain sends the peak of
/// each track and the dropped frames, and `Studio` is observable.
@MainActor
struct LevelTests {
    let folder: TemporaryFolder
    let url: URL
    let duo = InputDevice(
        uid: "duo", name: "Duo", nominalRate: 48_000, availableRates: [48_000...48_000], channelsPerBuffer: [2],
        latency: 0)!

    /// Track `t1` on channel 1 and track `t2` on channel 2 of `duo`.
    init() throws {
        folder = try TemporaryFolder()
        url = folder.url.appending(path: "Show.dirigible")
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.addTrack("t2", name: "Guest", layout: .mono)
        try session.setRoute(Route.device(uid: "duo", channels: .mono(1)), track: "t1")
        try session.setRoute(Route.device(uid: "duo", channels: .mono(2)), track: "t2")
        try session.write(to: url)
    }

    func studio(_ hal: TestHAL, ringSeconds: Double = 10) async throws -> Studio {
        let studio = try await Studio.open(url)
        studio.environment = .test(hal)
        studio.environment.ringSeconds = ringSeconds
        return studio
    }

    /// `seconds` of 10 ms records after now: a sine with amplitude 0.5 on channel 1 and silence on
    /// channel 2.
    func toneOnChannelOne(seconds: Double) -> [InputRecord] {
        let tone = sine(seconds: seconds, rate: 48_000)
        let interleaved = tone.flatMap { sample -> [Float] in [sample, 0] }
        let now = AudioConvertHostTimeToNanos(AudioGetCurrentHostTime()) + 100_000_000
        return records([interleaved], layout: [2], rate: 48_000, frames: 480, hostStart: now)
    }

    // MARK: Criterion 4

    /// Control in the same poll: the silent channel reads 0.
    @Test func eachTrackGetsThePeakOfItsOwnChannel() async throws {
        let hal = TestHAL([duo])
        let studio = try await studio(hal)
        try await studio.startRecording(armed: ["t1", "t2"], playhead: 0)
        let input = SyntheticInput(hal, "duo")
        // The 30 s tone of the monitor tests: it runs longer than the wait, and the stop ends it.
        input.play(await toneRecords(), pace: .realTime)

        // The main-actor suites hold the main actor for seconds (the `busy` limit of MonitorTests).
        await until(limit: .seconds(20), "t1 has no peak of 0.5") {
            abs((studio.liveTracks["t1"]?.peak ?? 0) - 0.5) <= 0.01
        }
        let silent = try #require(studio.liveTracks["t2"]?.peak)
        #expect(abs(silent) <= 1e-6)
        try await studio.stopRecording()
        await input.wait()
    }

    // MARK: Criterion 5

    /// A ring of 0.1 s gets 3 s of records at once, so it drops. Control: a ring of 10 s drops
    /// nothing.
    @Test(arguments: [0.1, 10])
    func droppedFramesReachTheStoredState(ringSeconds: Double) async throws {
        let hal = TestHAL([duo])
        let studio = try await studio(hal, ringSeconds: ringSeconds)
        try await studio.startRecording(armed: ["t1", "t2"], playhead: 0)
        let input = SyntheticInput(hal, "duo")
        input.play(toneOnChannelOne(seconds: 3), pace: .ignoreRoom)
        await input.wait()

        if ringSeconds < 1 {
            await until(limit: .seconds(2), "no dropped frames reached t1") {
                (studio.liveTracks["t1"]?.droppedFrames ?? 0) > 0
            }
        } else {
            try await Task.sleep(for: .seconds(1))
            #expect(studio.liveTracks["t1"]?.droppedFrames == 0)
        }
        try await studio.stopRecording()

        #expect(((studio.lastTake?.droppedFrames["t1"]) ?? 0 > 0) == (ringSeconds < 1))
    }

    // MARK: Criterion 6

    @Test func theViewsSeeTheStart() async throws {
        let studio = try await studio(TestHAL([duo]))
        let changed = Flag()
        withObservationTracking {
            _ = studio.transport
            _ = studio.liveTracks
        } onChange: {
            changed.set()
        }

        try await studio.startRecording(armed: ["t1", "t2"], playhead: 0)

        await until(limit: .seconds(1), "no change reached the observer") { changed.value }
        try await studio.stopRecording()
    }

    /// Control: with no take, the observer is not called.
    @Test func withNoTakeTheViewsSeeNoChange() async throws {
        let studio = try await studio(TestHAL([duo]))
        let changed = Flag()
        withObservationTracking {
            _ = studio.transport
            _ = studio.liveTracks
        } onChange: {
            changed.set()
        }

        try await Task.sleep(for: .milliseconds(300))

        #expect(!changed.value)
    }

    // MARK: The written span and the RMS of each arm (live take view C1, C2, C3)

    /// A mono device with a latency of 512 frames.
    let late = InputDevice(
        uid: "late", name: "Late", nominalRate: 48_000, availableRates: [48_000...48_000], channelsPerBuffer: [1],
        latency: 512)!

    /// A started writer of `tracks` on `device` that sends its reports to `log`. With `oneDrain`,
    /// the drain interval is 60 s, so the only drain is the drain of `finish`.
    func writer(
        _ device: InputDevice, _ hal: TestHAL, tracks: [(arm: Int, channels: Route.Channels)] = [(1, .mono(1))],
        log: ReportLog, oneDrain: Bool = false
    ) -> DeviceWriter {
        let url = folder.url
        let writer = DeviceWriter(
            device: device, tracks: tracks, files: TakeFiles(take: 1, folder: { url }), hal: hal.hal,
            report: log.closure, drainInterval: oneDrain ? .seconds(60) : .milliseconds(50),
            silenceLimit: noWatchdog, firstRecordLimit: noWatchdog)
        writer.start()
        return writer
    }

    /// One drain of 0.5 s of records from `takeStart`: the span is the raw host times of the
    /// records, with no latency. The report gives the latency of 512 frames in nanoseconds.
    @Test func aDrainReportsTheHostSpanOfItsRecords() async throws {
        let hal = TestHAL([late])
        let log = ReportLog()
        let writer = writer(late, hal, log: log, oneDrain: true)
        let input = SyntheticInput(hal, "late")
        var clock = DeviceClock()

        input.play(clock.run(seconds: 0.5))
        await input.wait()
        await writer.finish()

        let reports = log.all.filter { $0.arms != nil }
        #expect(reports.count == 1)
        let written = try #require(reports.first?.arms?[1]?.written, "no written span for the records")
        #expect(
            abs(nanos(from: takeStart, to: written.lowerBound)) <= 1000, "the span does not start at the first record")
        #expect(
            abs(nanos(from: takeStart + 500_000_000, to: written.upperBound)) <= 1000,
            "the span does not end at the end of the last record")
        let latency = try #require(reports.first?.latencyNanos)
        #expect(abs(latency - 10_666_667) <= 1000, "the latency is not 512 frames in nanoseconds")
    }

    /// The third record of one drain has a host time 50 ms before the first record. The span
    /// takes the smallest start and the largest end, and nothing traps.
    @Test func aHostTimeThatGoesBackDoesNotTrap() async throws {
        let hal = TestHAL([late])
        let log = ReportLog()
        let writer = writer(late, hal, log: log, oneDrain: true)
        let input = SyntheticInput(hal, "late")
        var clock = DeviceClock()
        var records = clock.run(seconds: 0.03)
        records[2] = InputRecord(
            sampleTime: records[2].sampleTime, hostTimeNanos: takeStart - 50_000_000, frameCount: 480,
            nominalRate: 48_000, buffers: records[2].buffers)!

        input.play(records)
        await input.wait()
        await writer.finish()

        let spans = log.all.compactMap { $0.arms?[1]?.written }
        let written = try #require(spans.first, "no written span when a host time goes back")
        #expect(
            abs(nanos(from: takeStart - 50_000_000, to: written.lowerBound)) <= 1000,
            "the span does not start at the smallest host time")
        #expect(
            abs(nanos(from: takeStart + 20_000_000, to: written.upperBound)) <= 1000,
            "the span does not end at the largest record end")
    }

    /// A forward gap of 10 ms at the first record of a drain: the writer fills it with silence,
    /// so the span of that drain starts 10 ms before the record.
    @Test func aSilenceFillExtendsTheSpan() async throws {
        let hal = TestHAL([late])
        let log = ReportLog()
        let writer = writer(late, hal, log: log)
        let input = SyntheticInput(hal, "late")
        var clock = DeviceClock()

        input.play(clock.run(seconds: 0.5))
        await input.wait()
        // The records after the ring is empty go to the next drain.
        await drained(hal, "late", limit: .seconds(20))
        clock.sampleTime += 480
        clock.hostNanos += 10_000_000
        let afterGap = UInt64(clock.hostNanos)
        input.play(clock.run(seconds: 0.5))
        await input.wait()
        await writer.finish()

        let starts = log.all.compactMap { $0.arms?[1]?.written?.lowerBound }
        #expect(
            starts.contains { abs(nanos(from: afterGap - 10_000_000, to: $0)) <= 1000 },
            "no span starts at the silence fill")
        #expect(!starts.contains { abs(nanos(from: afterGap, to: $0)) <= 1000 })
    }

    /// Drains with no record report no span for each arm. Control: after records, a span comes.
    @Test func aDrainWithNoRecordReportsNoSpan() async throws {
        let hal = TestHAL([duo])
        let log = ReportLog()
        let writer = writer(duo, hal, tracks: [(1, .mono(1)), (2, .mono(2))], log: log)
        await until(limit: .seconds(20), "no three drains") { log.all.count { $0.arms != nil } >= 3 }

        let empty = log.all.compactMap(\.arms)
        #expect(empty.allSatisfy { $0.keys.sorted() == [1, 2] })
        #expect(
            empty.allSatisfy { $0.values.allSatisfy { $0.written == nil } }, "a drain with no record has a written span"
        )

        let input = SyntheticInput(hal, "duo")
        input.play(toneOnChannelOne(seconds: 0.1))
        await input.wait()
        await until(limit: .seconds(20), "no span after records") {
            log.all.contains { $0.arms?[1]?.written != nil }
        }
        await writer.finish()
    }

    /// One record of 50 ms: 25 ms of a 750 Hz sine with amplitude 0.5 (-6 dBFS), then 25 ms with
    /// amplitude 0.1 (-20 dBFS). Each 256-frame block holds whole half periods, so the block
    /// RMS of the loud part is 0.5 / sqrt(2). The RMS of the whole record is 0.255.
    @Test func aDrainReportsTheLargestBlockRMS() async throws {
        let hal = TestHAL([late])
        let log = ReportLog()
        let writer = writer(late, hal, log: log, oneDrain: true)
        let input = SyntheticInput(hal, "late")
        var samples = sine(seconds: 0.05, rate: 48_000, frequency: 750)
        for index in 1200..<2400 { samples[index] *= 0.2 }

        input.play(records([samples], layout: [1], rate: 48_000, frames: 2400))
        await input.wait()
        await writer.finish()

        let levels = log.all.compactMap { $0.arms?[1] }
        let rms = try #require(levels.first?.rms)
        #expect(abs(rms - 0.5 / Float(2).squareRoot()) <= 1e-4, "the RMS is not the largest block RMS")
    }
}

/// A flag that any thread can set.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false

    var value: Bool { lock.withLock { isSet } }
    func set() { lock.withLock { isSet = true } }
}
