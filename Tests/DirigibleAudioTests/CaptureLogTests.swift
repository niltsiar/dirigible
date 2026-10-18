import CoreAudio
import DirigibleCore
import Foundation
import Testing
import os

@testable import DirigibleAudio

/// C20 to C26: the journal lines of the device writers, the app taps, the disk watch, and the
/// recovery of an open (decision 0059). The suite is serialized because its tests hold attaches.
@MainActor @Suite(.serialized)
struct CaptureLogTests {
    let folder: TemporaryFolder
    let logs: URL
    let log: DiagnosticLog
    let mic = InputDevice(
        uid: "mic", name: "USB Mic", nominalRate: 48_000, availableRates: [44_100...44_100, 48_000...48_000],
        channelsPerBuffer: [1], latency: 0)!

    init() throws {
        folder = try TemporaryFolder()
        logs = folder.url.appending(path: "logs")
        log = startLog(in: logs)
    }

    /// A started writer of channel 1 of `device`, which writes to the journal of the test.
    func writer(
        _ device: InputDevice, _ hal: TestHAL, drainInterval: Duration = .milliseconds(50),
        silenceLimit: Duration = noWatchdog, app: String? = nil
    ) -> DeviceWriter {
        let url = folder.url
        let writer = DeviceWriter(
            device: device, tracks: [(arm: 1, channels: .mono(1))], files: TakeFiles(take: 1, folder: { url }),
            hal: hal.hal, log: log, drainInterval: drainInterval, silenceLimit: silenceLimit,
            firstRecordLimit: silenceLimit, app: app)
        writer.start()
        return writer
    }

    /// `<category> <event>` and the fields of each line that is not an `app` line.
    func rows() -> [(event: String, fields: [String: String])] {
        TakeLogTests.lines(log, in: logs).map {
            $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        }
        .filter { $0.count >= 6 && !["app", "category"].contains($0[4]) }
        .map { ("\($0[4]) \($0[5])", fieldValues($0)) }
    }

    func fields(_ event: String) -> [[String: String]] { rows().filter { $0.event == event }.map(\.fields) }

    // MARK: C20

    /// The writer queue is held in the first attach while 500 device-list posts come, so one
    /// handler serves them all. The drain tick is 1 h away, so only the event makes the come-back.
    @Test func eachDeviceEventWritesOneLine() async throws {
        let hal = TestHAL([mic])
        hal.holdAttach("mic")
        defer { hal.releaseAttach("mic") }
        let writer = writer(mic, hal, drainInterval: .seconds(3_600))
        await until("no held attach") { hal.heldAttachCount("mic") == 1 }
        for _ in 0..<500 { writer.post(.devicesChanged, from: nil) }
        hal.releaseAttach("mic")
        await writer.started()
        let current = try #require(hal.current("mic"))
        writer.post(.rate(44_100), from: current)
        writer.post(.layout([1]), from: current)
        writer.post(.alive(true), from: current)
        writer.post(.alive(false), from: current)
        await writer.started()
        writer.post(.devicesChanged, from: nil)
        await writer.started()
        hal.detach(returns: false)
        await writer.finish()

        let rows = rows().filter { $0.event.hasPrefix("device ") && !$0.event.hasPrefix("device attach") }
        #expect(
            rows.map(\.event) == [
                "device devices-changed", "device rate", "device layout", "device alive", "device alive",
                "device lost", "device devices-changed", "device come-back", "device back", "device detach-failed",
            ], "\(rows.map(\.event))")
        #expect(rows.first?.fields["coalesced"] == "500", "\(rows.first?.fields ?? [:])")
        let values = rows.map { $0.fields.filter { $0.key != "device" } }
        #expect(
            values.dropFirst().prefix(5).map { $0 } == [
                ["rate": "44100"], ["channels": "1"], ["alive": "true"], ["alive": "false"], ["cause": "alive"],
            ])
        #expect(
            values.suffix(3).map { $0 } == [
                ["try": "1", "outcome": "attached", "wait_ms": "0.0"], [:], ["count": "1"],
            ])
        #expect(rows.allSatisfy { $0.fields["device"] == "USB Mic" })
    }

    /// Each loss names its cause: a new object ID in the device list, no record for the
    /// watchdog limit, and an attach that throws.
    @Test(arguments: ["list", "no-record", "attach-failed"])
    func eachLossNamesItsCause(cause: String) async throws {
        let hal = TestHAL([])
        hal.set("mic", id: 7, device: mic)
        if cause == "attach-failed" { hal.failAttach { _, _ in .status(kAudioHardwareUnspecifiedError) } }
        let writer = writer(mic, hal, silenceLimit: cause == "no-record" ? .milliseconds(200) : noWatchdog)
        await writer.started()
        if cause == "list" {
            hal.set("mic", id: 8)
            writer.post(.devicesChanged, from: nil)
        }
        await until(limit: .seconds(5), "no lost line") { !fields("device lost").isEmpty }
        await writer.finish()

        #expect(fields("device lost").first?["cause"] == cause, "\(fields("device lost"))")
    }

    /// A lost device that stays absent for 100 tries writes a `device come-back` line only at
    /// each try whose number is a power of two, and at the try that attaches. The drain tick is
    /// 1 h away, so each device-list event makes one try.
    @Test func aDeviceThatStaysAbsentWritesFewComeBackLines() async throws {
        let hal = TestHAL([mic])
        let writer = writer(mic, hal, drainInterval: .seconds(3_600))
        await writer.started()
        hal.set("mic", id: nil)
        for _ in 0..<100 {
            writer.post(.devicesChanged, from: nil)
            await writer.started()
        }
        hal.set("mic", id: 1)
        writer.post(.devicesChanged, from: nil)
        await writer.started()
        await writer.finish()

        let tries = fields("device come-back").map { "\($0["try"] ?? "?") \($0["outcome"] ?? "?")" }
        #expect(
            tries == [
                "1 absent", "2 absent", "4 absent", "8 absent", "16 absent", "32 absent", "64 absent", "101 attached",
            ], "\(tries.count) lines: \(tries.prefix(12))")
        #expect(fields("device back").count == 1)
    }

    // MARK: C21

    /// One sample-time jump of 2400 frames gives one line. 60 jumps in one second of the limit
    /// clock give one line with their count.
    @Test func anInputGapWritesItsFrames() async throws {
        let hal = TestHAL([mic])
        let writer = writer(mic, hal)
        let input = SyntheticInput(hal, "mic")
        var clock = DeviceClock()
        input.play(clock.run(seconds: 0.3))
        await input.wait()
        clock.sampleTime += 2_400
        clock.hostNanos += 50_000_000
        input.play(clock.run(seconds: 0.3))
        await input.wait()
        await writer.finish()

        #expect(fields("device input-gap") == [["device": "USB Mic", "frames": "2400", "count": "1"]])

        var limit = LineLimit()
        let start = ContinuousClock.now
        var lines: [(count: Int, sum: Int64)] = []
        for jump in 0..<60 {
            let now = start + .milliseconds(jump * 16)
            limit.add(2_400, at: now)
            if let line = limit.take(at: now) { lines.append(line) }
        }
        if let line = limit.take(at: start + .seconds(1)) { lines.append(line) }
        #expect(lines.map(\.count) == [60] && lines.map(\.sum) == [144_000], "\(lines)")
    }

    // MARK: C22

    /// Records with no valid times are dropped frames: one line with the total. 60 s of drains,
    /// 20 each second, with a drop in each, give one line or none for each second.
    @Test func droppedFramesWriteOneLineEachSecond() async throws {
        let hal = TestHAL([mic])
        let writer = writer(mic, hal)
        let input = SyntheticInput(hal, "mic")
        var clock = DeviceClock()
        input.play(clock.run(seconds: 0.1), flags: AudioTimeStampFlags())
        await input.wait()
        await writer.finish()

        #expect(fields("device dropped") == [["device": "USB Mic", "total": "4800", "new": "4800", "count": "1"]])

        var limit = LineLimit()
        let start = ContinuousClock.now
        var lines: [(count: Int, sum: Int64)] = []
        for drain in 0..<1_200 {
            let now = start + .milliseconds(drain * 50)
            limit.add(480, at: now)
            if let line = limit.take(at: now) { lines.append(line) }
        }
        if let line = limit.take(at: start + .seconds(60), force: true) { lines.append(line) }
        #expect(lines.count <= 60 && lines.reduce(0) { $0 + $1.count } == 1_200, "\(lines.count) lines")
    }

    // MARK: C23

    /// About 1200 drains of a quiet writer (1 ms each, 1.2 s of records) write no line between
    /// the attach and the finish. The segment proves that the drains wrote the records.
    @Test func aQuietTakeWritesNoLineBetweenStartAndStop() async throws {
        let hal = TestHAL([mic])
        let writer = writer(mic, hal, drainInterval: .milliseconds(1))
        let input = SyntheticInput(hal, "mic")
        var clock = DeviceClock()
        input.play(clock.run(seconds: 1.2), pace: .realTime)
        await input.wait()
        await writer.finish()

        #expect(FileManager.default.fileExists(atPath: folder.url.appending(path: "take1-1-1.caf").path))
        let events = rows().map(\.event)
        #expect(events == ["device attach-begin", "device attach"], "\(events.count) lines: \(events.prefix(8))")
    }

    // MARK: C24

    /// The silence warning, then a rebuild for each cause: the silence, a new process, a new
    /// output, and IsAlive false.
    @Test func anAppWriterWritesTheRebuildAndSilenceLines() async throws {
        let uid = AppTakeTests.zoomUID
        let hal = TestHAL([])
        func found(_ processes: [AudioObjectID], output: String) -> AppFound {
            AppFound(
                key: AppKey(processes: processes, output: output), output: output,
                device: InputDevice(
                    uid: uid, name: AppTakeTests.zoom, nominalRate: 48_000, availableRates: [48_000...48_000],
                    channelsPerBuffer: [1], latency: 0)!,
                playing: true)
        }
        hal.setApp(AppTakeTests.zoom, found([41], output: "BuiltInSpeakerDevice"))
        let device = InputDevice(
            uid: uid, name: "zoom.us", nominalRate: 48_000, availableRates: [48_000...48_000], channelsPerBuffer: [1],
            latency: 0)!
        let writer = writer(device, hal, app: AppTakeTests.zoom)
        await until("no first attach") { hal.inputs(uid).count == 1 }
        let input = SyntheticInput(hal, uid)
        var clock = DeviceClock()
        let zeros = clock.run(seconds: 6).map { record in
            var record = record
            record.buffers = [[Float](repeating: 0, count: record.frameCount)]
            return record
        }
        input.play(zeros)
        await input.wait()
        await until(limit: .seconds(5), "no silence rebuild") { hal.inputs(uid).count == 2 }
        hal.setApp(AppTakeTests.zoom, found([41, 42], output: "BuiltInSpeakerDevice"))
        writer.post(.devicesChanged, from: nil)
        await until("no process rebuild") { hal.inputs(uid).count == 3 }
        hal.setApp(AppTakeTests.zoom, found([41, 42], output: "USBHeadset"))
        writer.post(.devicesChanged, from: nil)
        await until("no output rebuild") { hal.inputs(uid).count == 4 }
        writer.post(.alive(false), from: hal.current(uid))
        await until("no alive rebuild") { hal.inputs(uid).count == 5 }
        await writer.finish()

        #expect(fields("tap silence") == [["app": AppTakeTests.zoom]])
        let causes = ["silence-5s", "processes", "output", "alive"]
        #expect(fields("tap rebuild-begin").map { $0["cause"] } == causes)
        #expect(fields("tap rebuild").map { $0["cause"] } == causes)
    }

    // MARK: C25

    /// The free bytes go 6 GB, 4 GB, 4 GB, 1.5 GB, and 0.5 GB: one line at each crossing of 5 GB and
    /// 2 GB, and the `.diskLow` stop.
    @Test func aDiskCrossingWritesOneLine() async throws {
        let url = folder.url.appending(path: "Show.dirigible")
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.setRoute(.device(uid: "mic", channels: .mono(1)), track: "t1")
        try session.write(to: url)
        let free = CountedFreeBytes(6_000_000_000)
        let studio = try await Studio.open(url, log: log)
        studio.environment = .test(TestHAL([mic]))
        studio.environment.freeBytes = { _ in free.read() }
        studio.environment.log = log
        try await studio.startRecording(armed: ["t1"], playhead: 0)
        for bytes: Int64 in [6_000_000_000, 4_000_000_000, 4_000_000_000, 1_500_000_000] {
            let reads = free.set(bytes)
            await until(limit: .seconds(5), "no disk check at \(bytes)") { free.reads > reads }
        }
        free.set(500_000_000)
        await until(limit: .seconds(5), "no diskLow stop") { studio.lastTake != nil }
        await studio.settle()

        #expect(
            fields("disk threshold") == [
                ["below": "5000000000", "free": "4000000000"], ["below": "2000000000", "free": "1500000000"],
            ], "\(fields("disk threshold"))")
        #expect(fields("take stopped").map { $0["cause"] } == ["diskLow"])
    }

    /// A segment write that fails writes `disk write-failed` with the arm and the status.
    @Test func aWriteFailureWritesItsStatus() async throws {
        try FileManager.default.createDirectory(
            at: folder.url.appending(path: "take1-1-1.sidecar"), withIntermediateDirectories: true)
        let hal = TestHAL([mic])
        let writer = writer(mic, hal)
        let input = SyntheticInput(hal, "mic")
        var clock = DeviceClock()
        input.play(clock.run(seconds: 0.3))
        await input.wait()
        await writer.finish()

        #expect(fields("disk write-failed") == [["device": "USB Mic", "arm": "1", "status": "\(EISDIR)"]])
    }

    // MARK: C26

    /// An open with a pending take writes the recovery lines. A CAF that does not open names its
    /// segment; control: a take that reads gives no `recovery unreadable` line.
    @Test(arguments: [false, true])
    func anOpenWithAPendingTakeWritesTheRecovery(unreadable: Bool) async throws {
        let package = try TakePackage(tracks: [("t1", .mono), ("t2", .mono)])
        try package.segment(arm: 1, samples: sine(seconds: 2, rate: 48_000))
        try package.segment(arm: 2, samples: sine(seconds: 2, rate: 48_000, frequency: 500))
        let caf = package.capture.appending(path: "take1-1-1.caf")
        if unreadable { chmod(caf.path, 0o000) }
        defer { chmod(caf.path, 0o644) }

        let studio = try await Studio.open(package.url, log: log)

        #expect((studio.pendingTake != nil) == unreadable)
        #expect(fields("recovery found") == [["take": "1", "segments": "2"]])
        #expect(fields("recovery unreadable") == (unreadable ? [["segment": "take1-1-1"]] : []))
        let done = try #require(fields("recovery done").first)
        #expect(done["ms"] != nil && done["error"] == (unreadable ? "finalize" : nil), "\(done)")
    }
}

/// The free bytes of a test volume, with the count of the reads, so a test waits for a disk
/// check after it sets a value.
final class CountedFreeBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int64
    private var count = 0

    init(_ bytes: Int64) { self.bytes = bytes }

    func read() -> Int64 {
        lock.withLock {
            count += 1
            return bytes
        }
    }

    var reads: Int { lock.withLock { count } }

    /// Sets the value and returns the read count after the change.
    @discardableResult
    func set(_ value: Int64) -> Int {
        lock.withLock {
            bytes = value
            return count
        }
    }
}
