import CoreAudio
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The reports of the device writers of one test.
final class ReportLog: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [Report] = []

    var closure: @Sendable (Report) -> Void { { [self] report in lock.withLock { reports.append(report) } } }
    var count: Int { lock.withLock { reports.count } }
    func states(arm: Int) -> [LiveTrack.State] { lock.withLock { reports.filter { $0.arm == arm }.map(\.state) } }
}

/// The device events of one writer (criteria 6 to 9, 19 to 21), and the take with a device that
/// is gone (criterion 15). Each test has its control.
@MainActor
struct DeviceEventTests {
    let folder: TemporaryFolder
    let log = ReportLog()
    let mic = InputDevice(
        uid: "mic", name: "USB Mic", nominalRate: 48_000, availableRates: [44_100...44_100, 48_000...48_000],
        channelsPerBuffer: [1], latency: 0)!
    let duo = InputDevice(
        uid: "duo", name: "Duo", nominalRate: 48_000, availableRates: [48_000...48_000], channelsPerBuffer: [2],
        latency: 0)!

    init() throws { folder = try TemporaryFolder() }

    /// A started writer of arm `arm` on channel `channel` of `device`. The watchdog limit is long
    /// unless a test sets it.
    func writer(
        _ device: InputDevice, _ hal: TestHAL, arm: Int = 1, channel: Int = 1, silenceLimit: Duration = .seconds(60)
    ) -> DeviceWriter {
        let writer = DeviceWriter(
            device: device, tracks: [(arm: arm, channels: .mono(channel))], take: 1, folder: folder.url,
            hal: hal.hal, report: log.closure, silenceLimit: silenceLimit)
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

    /// Waits until the writer drained the ring of the current input of `uid`.
    func drained(_ hal: TestHAL, _ uid: String) async {
        await until("the ring of \(uid) is not empty") { hal.current(uid)?.ring.isEmpty ?? true }
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
                Sidecar.decode(Data(contentsOf: folder.url.appending(path: "take1-1-2.sidecar"))))
            #expect(sidecar.header.nominalRate == 44_100)
        }
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

        writer.post(.layout([2]), from: old)
        writer.post(.alive(false), from: old)
        writer.post(.devicesChanged, from: nil)
        await writer.finish()

        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path).sorted() == files)
        #expect(log.count == 0)
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

    // MARK: Criterion 19: a silent or replaced device

    /// The producers start before the attach and wait for it, so a test that waits on the main
    /// actor cannot hold the records back past the watchdog limit.
    @Test func theWatchdogLosesASilentDeviceAndTheRetryAttachesAgain() async throws {
        let hal = TestHAL([mic])
        let input = SyntheticInput(hal, "mic")
        var clock = DeviceClock()
        input.play(run(&clock, 0.5))
        clock.sampleTime = 0
        input.play(run(&clock, 0.5), attach: 2)
        let writer = writer(mic, hal, silenceLimit: .seconds(1))

        await until(limit: .seconds(5), "no second attach") { hal.inputs("mic").count >= 2 }
        await input.wait()
        let gaps = await writer.finish()

        #expect(try stems() == ["take1-1-1", "take1-1-2"])
        #expect(gaps == [1: .deviceLost])
        #expect(log.states(arm: 1).starts(with: [.deviceLost, .recording]))
    }

    /// Control of the watchdog: records with no pause keep the device. The producer still sends
    /// when `finish()` detaches it.
    @Test func aDeviceWithNoPauseKeepsItsFirstAttach() async throws {
        let hal = TestHAL([mic])
        let input = SyntheticInput(hal, "mic")
        var clock = DeviceClock()
        input.play(run(&clock, 10), pace: .realTime)
        let writer = writer(mic, hal, silenceLimit: .seconds(1))

        try await Task.sleep(for: .seconds(2))
        let gaps = await writer.finish()
        await input.wait()

        #expect(hal.tries("mic").count == 1)
        #expect(try stems() == ["take1-1-1"])
        #expect(gaps == [:])
    }

    @Test(arguments: [false, true])
    func aNewObjectIDIsALossAndABack(changed: Bool) async throws {
        let hal = TestHAL([])
        hal.set("mic", id: 7, device: mic)
        let writer = writer(mic, hal)
        let input = SyntheticInput(hal, "mic")
        var clock = DeviceClock()
        input.play(run(&clock, 0.3))
        await input.wait()

        if changed { hal.set("mic", id: 8) }
        writer.post(.devicesChanged, from: nil)
        if changed {
            await until("no attach for object 8") { hal.inputs("mic").last?.id == 8 }
            clock.sampleTime = 0
        }
        input.play(run(&clock, 0.3))
        await input.wait()
        let gaps = await writer.finish()

        #expect(hal.inputs("mic").map(\.id) == (changed ? [7, 8] : [7]))
        #expect(try stems() == (changed ? ["take1-1-1", "take1-1-2"] : ["take1-1-1"]))
        #expect(gaps == (changed ? [1: .deviceLost] : [:]))
    }

    /// A late IsAlive event of the old appearance does nothing. Control: the same event from the
    /// current appearance is a loss, and the back gives a third segment.
    @Test(arguments: [false, true])
    func anEventFromAnOldAppearanceDoesNothing(fromCurrent: Bool) async throws {
        let hal = TestHAL([])
        hal.set("mic", id: 7, device: mic)
        let writer = writer(mic, hal)
        let input = SyntheticInput(hal, "mic")
        var clock = DeviceClock()
        input.play(run(&clock, 0.3))
        await input.wait()
        hal.set("mic", id: 8)
        writer.post(.devicesChanged, from: nil)
        await until("no attach for object 8") { hal.inputs("mic").last?.id == 8 }
        clock.sampleTime = 0
        input.play(run(&clock, 0.3))
        await input.wait()

        let inputs = hal.inputs("mic")
        writer.post(.alive(false), from: fromCurrent ? inputs[1] : inputs[0])
        writer.post(.devicesChanged, from: nil)
        if fromCurrent {
            await until("no second attach for object 8") { hal.inputs("mic").count == 3 }
            clock.sampleTime = 0
        }
        input.play(run(&clock, 0.2))
        await input.wait()
        await writer.finish()

        #expect(hal.inputs("mic").map(\.id) == (fromCurrent ? [7, 8, 8] : [7, 8]))
        #expect(
            try stems() == (fromCurrent ? ["take1-1-1", "take1-1-2", "take1-1-3"] : ["take1-1-1", "take1-1-2"]))
    }

    // MARK: Criterion 20: retry while lost

    @Test(arguments: [false, true])
    func aLostDeviceTriesAgainEachSecond(comesBack: Bool) async throws {
        let hal = TestHAL([mic])
        let writer = writer(mic, hal)
        let input = SyntheticInput(hal, "mic")
        var clock = DeviceClock()
        input.play(run(&clock, 0.5))
        await input.wait()

        hal.set("mic", id: nil)
        writer.post(.alive(false), from: hal.current("mic"))
        await until("mic is not lost") { log.states(arm: 1) == [.deviceLost] }
        hal.failAttach { _, count in count == 2 || !comesBack ? .status(kAudioHardwareBadDeviceError) : nil }
        hal.set("mic", id: 1)
        if comesBack {
            await until(limit: .seconds(3), "mic did not come back") { log.states(arm: 1).last == .recording }
            clock.sampleTime = 0
            input.play(run(&clock, 0.5))
            await input.wait()
        } else {
            await until(limit: .seconds(2), "no retry") { hal.tries("mic").count >= 2 }
        }
        let gaps = await writer.finish()

        #expect(gaps == [1: .deviceLost])
        if comesBack {
            let tries = hal.tries("mic")
            #expect(tries.count == 3)
            #expect(tries[1].ring.context == tries[2].ring.context)
            #expect(try stems() == ["take1-1-1", "take1-1-2"])
        } else {
            #expect(log.states(arm: 1) == [.deviceLost])
            #expect(try stems() == ["take1-1-1"])
        }
    }
}
