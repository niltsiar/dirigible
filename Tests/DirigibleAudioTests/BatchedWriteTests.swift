import AudioToolbox
import DirigibleCore
import Foundation
import Testing
import os

@testable import DirigibleAudio

/// The CAF appends of one writer (decision 0004): each drain writes the frames of each file with
/// one append, and the files are the same as with one append for each record.
@MainActor
struct BatchedWriteTests {
    let folder: TemporaryFolder
    let log = ReportLog()
    let duo = InputDevice(
        uid: "duo", name: "Duo", nominalRate: 48_000, availableRates: [48_000...48_000], channelsPerBuffer: [2],
        latency: 0)!

    init() throws { folder = try TemporaryFolder() }

    /// A started writer of arm 1 on channel 1 and arm 2 on channel 2 of `duo`, into `folder`.
    func writer(_ hal: TestHAL, drain: Duration, into folder: URL) -> DeviceWriter {
        let writer = DeviceWriter(
            device: duo, tracks: [(arm: 1, channels: .mono(1)), (arm: 2, channels: .mono(2))],
            files: TakeFiles(take: 1, folder: { folder }), hal: hal.hal, report: log.closure, drainInterval: drain,
            silenceLimit: noWatchdog, firstRecordLimit: noWatchdog)
        writer.start()
        return writer
    }

    /// Records of `seconds` from `clock` in `layout`: one buffer of 2 channels ([2]) or 2 mono
    /// buffers ([1, 1]). Record number `n`, counted by `next`, has the value n / 1000 on channel 1
    /// and -n / 1000 on channel 2, so a change of order shows in the samples.
    func run(_ clock: inout DeviceClock, _ seconds: Double, layout: [Int], next: inout Int) -> [InputRecord] {
        clock.run(seconds: seconds).map { record in
            var record = record
            let value = Self.value(record: next, arm: 1)
            next += 1
            let frames = record.frameCount
            record.buffers =
                layout == [2]
                ? [(0..<frames * 2).map { $0 % 2 == 0 ? value : -value }]
                : [[Float](repeating: value, count: frames), [Float](repeating: -value, count: frames)]
            return record
        }
    }

    /// The sample value of record `record` for `arm`.
    static func value(record: Int, arm: Int) -> Float {
        let value = Float(record) / 1000
        return arm == 1 ? value : -value
    }

    func samples(_ stem: String, in folder: URL) throws -> [Float] {
        try readAudio(folder.appending(path: "\(stem).caf")).samples
    }

    /// The CAF and sidecar names in `folder`, sorted.
    func files(_ folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".caf") || $0.hasSuffix(".sidecar") }.sorted()
    }

    /// 3 s of records in one drain (the finish runs it): each file gets an append for each
    /// second of frames, not one for each 10 ms record, and holds every frame.
    @Test func aDrainWritesOneAppendForEachFile() async throws {
        let hal = TestHAL([duo])
        let writer = writer(hal, drain: .seconds(60), into: folder.url)
        let input = SyntheticInput(hal, "duo")
        var clock = DeviceClock()
        var next = 0

        input.play(run(&clock, 3, layout: [2], next: &next), pace: .burst)
        await input.wait()
        await writer.finish()

        for arm in [1, 2] {
            let stats = try #require(writer.tracks.appendStats[arm], "arm \(arm) closed no segment")
            #expect(stats.count <= 4, "arm \(arm) has \(stats.count) appends")
            #expect(stats.largest <= 48_480, "arm \(arm) has an append of \(stats.largest) frames")
            #expect(try samples("take1-\(arm)-1", in: folder.url).count == 144_000)
        }
    }

    /// Slow: a thread writes a file of the take folder and flushes it with `F_FULLFSYNC` in a
    /// loop, as the saves of other work do. A writer with a drain each 50 ms still writes about
    /// one append for each file and drain of 3 s of real-time records.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aDrainUnderASyncLoopKeepsUpWithRealTime() async throws {
        let descriptor = open(
            folder.url.appending(path: "sync.bin").path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        try #require(descriptor >= 0, "sync.bin did not open: errno \(errno)")
        let stopped = OSAllocatedUnfairLock(initialState: false)
        defer { stopped.withLock { $0 = true } }
        let syncs = Thread {
            defer { close(descriptor) }
            var byte: UInt8 = 1
            while !stopped.withLock({ $0 }) {
                _ = write(descriptor, &byte, 1)
                _ = fcntl(descriptor, F_FULLFSYNC)
            }
        }
        syncs.start()
        let hal = TestHAL([duo])
        let writer = writer(hal, drain: .milliseconds(50), into: folder.url)
        let input = SyntheticInput(hal, "duo")
        var clock = DeviceClock()
        var next = 0

        input.play(run(&clock, 3, layout: [2], next: &next), pace: .realTime)
        await input.wait()
        await writer.finish()

        for arm in [1, 2] {
            let stats = try #require(writer.tracks.appendStats[arm], "arm \(arm) closed no segment")
            // 25 for each audio second: 20 drains and the checkpoints.
            #expect(stats.count <= 75, "arm \(arm) has \(stats.count) appends")
            #expect(try samples("take1-\(arm)-1", in: folder.url).count == 144_000)
        }
    }

    /// One record list into two take folders: one drain for the whole list (`pace: .burst`), and
    /// a drain each 50 ms at real time. The list has 1.9 s, a jump of 0.3 s (a silence fill),
    /// 0.8 s, one record of a new layout (a segment of one record), a jump of 3 s (a new
    /// segment), and 0.5 s. Both folders get the same files, byte for byte, with the input
    /// samples in order, and a drain leaves no frame out of the open file.
    @Test func aBatchedDrainWritesTheSameFilesAsSmallDrains() async throws {
        var clock = DeviceClock()
        var next = 0
        var records = run(&clock, 1.9, layout: [2], next: &next)
        clock.sampleTime += 14_400
        clock.hostNanos += 300_000_000
        records += run(&clock, 0.8, layout: [2], next: &next)
        records += run(&clock, 0.01, layout: [1, 1], next: &next)
        clock.sampleTime += 3 * 48_000
        clock.hostNanos += 3_000_000_000
        records += run(&clock, 0.5, layout: [1, 1], next: &next)
        try #require(records.count == 321)

        let burstHAL = TestHAL([duo])
        let burst = writer(burstHAL, drain: .seconds(60), into: folder.url)
        let burstInput = SyntheticInput(burstHAL, "duo")
        burstInput.play(records, pace: .burst)
        await burstInput.wait()
        await burst.finish()

        let small = try TemporaryFolder()
        let smallHAL = TestHAL([duo])
        let drains = writer(smallHAL, drain: .milliseconds(50), into: small.url)
        let smallInput = SyntheticInput(smallHAL, "duo")
        smallInput.play(records, pace: .realTime)
        await smallInput.wait()
        await drained(smallHAL, "duo")
        // A job on the writer queue after the drain that popped the last record.
        await drains.started()
        for arm in [1, 2] {
            let caf = small.url.appending(path: "take1-\(arm)-3.caf")
            let size = try #require(try FileManager.default.attributesOfItem(atPath: caf.path)[.size] as? Int)
            let offset = try dataOffset(caf)
            #expect(size == offset + 24_000 * 4, "the open CAF of arm \(arm) has \(size - offset) bytes of frames")
        }
        await drains.finish()

        for arm in [1, 2] {
            let stats = try #require(burst.tracks.appendStats[arm], "arm \(arm) closed no segment")
            #expect(stats.largest <= 48_480, "arm \(arm) has an append of \(stats.largest) frames")
        }
        let names = try files(folder.url)
        #expect(names.count == 12, "\(names)")
        #expect(try files(small.url) == names)
        for name in names {
            let same =
                try Data(contentsOf: folder.url.appending(path: name))
                == Data(contentsOf: small.url.appending(path: name))
            #expect(same, "\(name) differs")
        }
        func frames(_ list: Range<Int>, arm: Int) -> [Float] {
            list.flatMap { [Float](repeating: Self.value(record: $0, arm: arm), count: 480) }
        }
        for arm in [1, 2] {
            let segments = [
                frames(0..<190, arm: arm) + [Float](repeating: 0, count: 14_400) + frames(190..<270, arm: arm),
                frames(270..<271, arm: arm), frames(271..<321, arm: arm),
            ]
            for (index, expected) in segments.enumerated() {
                let found = try samples("take1-\(arm)-\(index + 1)", in: folder.url)
                #expect(
                    found == expected,
                    "take1-\(arm)-\(index + 1) has \(found.count) frames, expected \(expected.count) in input order")
            }
        }
    }

    /// The byte offset of the audio data in the CAF at `url`.
    func dataOffset(_ url: URL) throws -> Int {
        var opened: AudioFileID?
        try #require(AudioFileOpenURL(url as CFURL, .readPermission, kAudioFileCAFType, &opened) == noErr)
        let file = try #require(opened)
        defer { AudioFileClose(file) }
        var offset: Int64 = 0
        var size = UInt32(MemoryLayout<Int64>.size)
        let status = AudioFileGetProperty(file, kAudioFilePropertyDataOffset, &size, &offset)
        try #require(status == noErr, "no data offset: \(status)")
        return Int(offset)
    }
}
