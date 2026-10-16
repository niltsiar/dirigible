import CoreAudio
import DirigibleCore
import Foundation
import Testing
import os

@testable import DirigibleAudio

/// The reports of the device writers of one test.
final class ReportLog: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [Report] = []

    var closure: @Sendable (Report) -> Void { { [self] report in lock.withLock { reports.append(report) } } }
    /// The state reports. Each drain also sends a `.levels` report.
    var count: Int {
        lock.withLock {
            reports.count {
                if case .state = $0 { true } else { false }
            }
        }
    }
    /// Every report, in order.
    var all: [Report] { lock.withLock { reports } }
    func states(arm: Int) -> [LiveTrack.State] { lock.withLock { reports.compactMap { $0.state(arm: arm) }.map(\.0) } }
    func statuses(arm: Int) -> [Int32?] { lock.withLock { reports.compactMap { $0.state(arm: arm) }.map(\.1) } }
}

/// The device events of one writer (criteria 6 to 9, 19 to 21), and the take with a device that
/// is gone (criterion 15). Each test has its control.
@MainActor
struct DeviceEventTests {
    /// The limit of a wait for a Studio state, which a report hop sets on the main actor. In a
    /// full suite, the `@MainActor` suites hold it for seconds (the `busy` limit of MonitorTests).
    let busy = Duration.seconds(20)
    let folder: TemporaryFolder
    let log = ReportLog()
    let mic = InputDevice(
        uid: "mic", name: "USB Mic", nominalRate: 48_000, availableRates: [44_100...44_100, 48_000...48_000],
        channelsPerBuffer: [1], latency: 0)!
    let duo = InputDevice(
        uid: "duo", name: "Duo", nominalRate: 48_000, availableRates: [48_000...48_000], channelsPerBuffer: [2],
        latency: 0)!

    init() throws { folder = try TemporaryFolder() }

    /// A started writer of arm `arm` on channel `channel` of `device`. The watchdog limit is `noWatchdog`
    /// unless a test sets it. The first-record limit is the watchdog limit unless a test sets it.
    func writer(
        _ device: InputDevice, _ hal: TestHAL, arm: Int = 1, channel: Int = 1, silenceLimit: Duration = noWatchdog,
        firstRecordLimit: Duration? = nil
    ) -> DeviceWriter {
        let url = folder.url
        let writer = DeviceWriter(
            device: device, tracks: [(arm: arm, channels: .mono(channel))], files: TakeFiles(take: 1, folder: { url }),
            hal: hal.hal, report: log.closure, silenceLimit: silenceLimit,
            firstRecordLimit: firstRecordLimit ?? silenceLimit)
        writer.start()
        return writer
    }

    /// The segment stems in the folder, sorted.
    func stems() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.url.path)
            .filter { $0.hasSuffix(".caf") }.map { String($0.dropLast(4)) }.sorted()
    }

    func samples(_ stem: String) throws -> [Float] {
        try readAudio(folder.url.appending(path: "\(stem).caf")).samples
    }

    /// Records of `seconds` from `clock` with `layout`, each sample `value`.
    func run(_ clock: inout DeviceClock, _ seconds: Double, layout: [Int] = [1], value: Float = 0.25) -> [InputRecord] {
        clock.run(seconds: seconds).map { record in
            var record = record
            record.buffers = layout.map { [Float](repeating: value, count: record.frameCount * $0) }
            return record
        }
    }

    // MARK: Criterion 6: rate

    @Test(arguments: [false, true])
    func aRateEventStartsASegmentAtTheNewRate(event: Bool) async throws {
        let hal = TestHAL([mic])
        let writer = writer(mic, hal)
        let input = SyntheticInput(hal, "mic")
        var clock = DeviceClock()

        input.play(run(&clock, 0.5))
        await input.wait()
        if event {
            let current = try #require(hal.current("mic"))
            current.ring.setRate(44_100)
            writer.post(.rate(44_100), from: current)
            clock.headerRate = 44_100
            clock.realRate = 44_100
        }
        input.play(run(&clock, 0.5))
        await input.wait()
        await writer.finish()

        #expect(try stems() == (event ? ["take1-1-1", "take1-1-2"] : ["take1-1-1"]))
        if event {
            let sidecar = try #require(
                try Sidecar.decode(Data(contentsOf: folder.url.appending(path: "take1-1-2.sidecar"))))
            #expect(sidecar.header.nominalRate == 44_100)
        }
    }

    /// A rate that needs a larger ring starts a new appearance with a new ring, and no gap.
    /// Control: a lower rate keeps the first appearance.
    @Test(arguments: [44_100.0, 192_000.0])
    func aHigherRateStartsANewAppearanceWithALargerRing(rate: Double) async throws {
        let hal = TestHAL([mic])
        let writer = writer(mic, hal)
        await until("no first attach") { hal.inputs("mic").count == 1 }
        let faster = try #require(
            InputDevice(
                uid: "mic", name: "USB Mic", nominalRate: rate, availableRates: mic.availableRates,
                channelsPerBuffer: [1], latency: 0))
        hal.set("mic", id: 1, device: faster)

        writer.post(.rate(rate), from: hal.current("mic"))
        let gaps = await writer.finish()

        #expect(hal.capacities("mic") == (rate > 48_000 ? [4_194_304, 16_777_216] : [4_194_304]))
        #expect(gaps == [:])
        #expect(!log.states(arm: 1).contains(.deviceLost))
    }

    // MARK: Criterion 7: format

    @Test(arguments: [false, true])
    func aLayoutEventWithTheChannelStartsAMonoSegment(event: Bool) async throws {
        let hal = TestHAL([mic])
        let writer = writer(mic, hal)
        let input = SyntheticInput(hal, "mic")
        var clock = DeviceClock()

        input.play(run(&clock, 0.5))
        await input.wait()
        await drained(hal, "mic")
        if event { writer.post(.layout([2]), from: hal.current("mic")) }
        input.play(run(&clock, 0.5, layout: event ? [2] : [1]))
        await input.wait()
        await writer.finish()

        if event {
            #expect(try stems() == ["take1-1-1", "take1-1-2"])
            #expect(try samples("take1-1-1").count == 24_000)
            #expect(try samples("take1-1-2").count == 24_000)
        } else {
            #expect(try stems() == ["take1-1-1"])
            #expect(try samples("take1-1-1").count == 48_000)
        }
    }

    /// Every record that the ring gives is written or counted as dropped. With no layout event,
    /// records of a new layout with the routed channel (a second buffer) re-route the track into
    /// a new segment. Records of a layout without the routed channel, and records without valid
    /// times, are dropped and counted.
    @Test(arguments: [
        ([1, 1], true, ["take1-1-1", "take1-1-2"], 0),
        ([1], true, ["take1-1-1"], 24_000),
        ([2], false, ["take1-1-1"], 24_000),
    ])
    func eachRecordIsWrittenOrCountedAsDropped(
        layout: [Int], valid: Bool, expected: [String], dropped: Int
    ) async throws {
        let hal = TestHAL([duo])
        let writer = writer(duo, hal, channel: 2)
        let input = SyntheticInput(hal, "duo")
        var clock = DeviceClock()
        input.play(run(&clock, 0.5, layout: [2]))
        await input.wait()
        await drained(hal, "duo")

        input.play(run(&clock, 0.5, layout: layout), flags: valid ? validTimes : [])
        await input.wait()
        await drained(hal, "duo")
        await writer.finish()

        #expect(try stems() == expected)
        #expect(try expected.map { try samples($0).count } == expected.map { _ in 24_000 })
        #expect(writer.droppedFrames == dropped)
    }

    @Test func aLayoutWithoutTheRoutedChannelLosesTheDeviceAndTheOtherDeviceRecords() async throws {
        let hal = TestHAL([mic, duo])
        let micWriter = writer(mic, hal)
        let duoWriter = writer(duo, hal, arm: 2, channel: 2)
        let micInput = SyntheticInput(hal, "mic")
        let duoInput = SyntheticInput(hal, "duo")
        var micClock = DeviceClock()
        var duoClock = DeviceClock()

        micInput.play(run(&micClock, 1))
        duoInput.play(run(&duoClock, 0.5, layout: [2]))
        await duoInput.wait()
        // The device now has one channel, so the retry does not find channel 2 either.
        hal.set(
            "duo", id: 2,
            device: InputDevice(
                uid: "duo", name: "Duo", nominalRate: 48_000, availableRates: [], channelsPerBuffer: [1], latency: 0))
        duoWriter.post(.layout([1]), from: hal.current("duo"))
        await until("duo is not lost") { log.states(arm: 2).contains(.deviceLost) }
        await micInput.wait()
        await micWriter.finish()
        let gaps = await duoWriter.finish()

        #expect(gaps == [2: .deviceLost])
        #expect(try stems() == ["take1-1-1", "take1-2-1"])
        #expect(try samples("take1-1-1").count == 48_000)
        #expect(try samples("take1-2-1").count == 24_000)
    }

    // MARK: Criterion 9: stale events

    @Test func anEventAfterFinishChangesNothing() async throws {
        let hal = TestHAL([mic])
        let writer = writer(mic, hal)
        let input = SyntheticInput(hal, "mic")
        var clock = DeviceClock()
        input.play(run(&clock, 0.5))
        await input.wait()
        await writer.finish()
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.url.path).sorted()
        let old = hal.inputs("mic").last
        let reported = log.count

        writer.post(.layout([2]), from: old)
        writer.post(.alive(false), from: old)
        writer.post(.devicesChanged, from: nil)
        await writer.finish()

        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path).sorted() == files)
        #expect(log.count == reported)
        #expect(hal.tries("mic").count == 1)
    }

    /// Control of criterion 9: the same layout event before `finish()` breaks the segment.
    @Test func theSameEventBeforeFinishBreaksTheSegment() async throws {
        let hal = TestHAL([mic])
        let writer = writer(mic, hal)
        let input = SyntheticInput(hal, "mic")
        var clock = DeviceClock()
        input.play(run(&clock, 0.5))
        await input.wait()
        await drained(hal, "mic")

        writer.post(.layout([1]), from: hal.current("mic"))
        input.play(run(&clock, 0.5))
        await input.wait()
        await writer.finish()

        #expect(try stems() == ["take1-1-1", "take1-1-2"])
    }
}

extension Report {
    /// The state and the status of a `.state` report of `arm`. Nil for another arm and for `.levels`.
    func state(arm: Int) -> (LiveTrack.State, Int32?)? {
        guard case .state(_, arm, let state, let status) = self else { return nil }
        return (state, status)
    }

    /// The level of each arm of a `.levels` report. Nil for a `.state` report.
    var arms: [Int: ArmLevel]? {
        guard case .levels(_, let arms, _, _) = self else { return nil }
        return arms
    }

    /// The device latency in nanoseconds of a `.levels` report. Nil for a `.state` report.
    var latencyNanos: Int64? {
        guard case .levels(_, _, let latency, _) = self else { return nil }
        return latency
    }
}

// MARK: C3 of record-start-hang: the come-back tries of a lost writer

extension DeviceEventTests {
    /// Every attach throws `.undone`, and 500 device-list events come right after the start. The
    /// failed start try opens a backoff window, so the events make one more try at the end of the
    /// window, not one try for each event: each try comes 250 ms or more after the one before.
    @Test func aDeviceListStormMakesOneTryPerBackoffWindow() async throws {
        let hal = TestHAL([mic])
        let times = OSAllocatedUnfairLock(initialState: [ContinuousClock.Instant]())
        hal.failAttach { _, _ in
            times.withLock { $0.append(.now) }
            return .undone(kAudioHardwareUnspecifiedError)
        }
        let writer = writer(mic, hal)
        for _ in 0..<500 { writer.post(.devicesChanged, from: nil) }
        await writer.started()
        await until("no try at the end of the window") { hal.tries("mic").count >= 2 }
        await writer.finish()
        let tries = times.withLock { $0 }

        let gaps = zip(tries, tries.dropFirst()).map { $1 - $0 }
        #expect(tries.count >= 2)
        #expect(gaps.allSatisfy { $0 >= .milliseconds(250) }, "tries \(tries.count), gaps \(gaps)")
    }
}
