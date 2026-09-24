import CoreAudio
import Foundation
import Testing

@testable import DirigibleAudio

/// The ring of one device appearance, its C IOProc, and the drain into the device writer
/// (criteria 2, 3, and 21 (a)).
@MainActor
struct CaptureRingTests {
    let folder: TemporaryFolder
    let stereo = InputDevice(
        uid: "mic", name: "USB Mic", nominalRate: 48_000, availableRates: [48_000...48_000], channelsPerBuffer: [2],
        latency: 0)!

    init() throws { folder = try TemporaryFolder() }

    /// A writer of one stereo track on `stereo`, started on a test HAL.
    func writer(
        _ hal: TestHAL, drainInterval: Duration = .milliseconds(50), ringSeconds: Double = 10
    ) -> DeviceWriter {
        let url = folder.url
        let writer = DeviceWriter(
            device: stereo, tracks: [(arm: 1, channels: .stereo(1, 2))], take: 1, folder: { url }, hal: hal.hal,
            drainInterval: drainInterval, silenceLimit: .seconds(60), ringSeconds: ringSeconds)
        writer.start()
        return writer
    }

    var caf: URL { folder.url.appending(path: "take1-1-1.caf") }

    @Test func oneSecondAtRealTimePaceReachesTheSegment() async throws {
        let hal = TestHAL([stereo])
        let writer = writer(hal)
        let samples = sine(seconds: 1, rate: 48_000, channels: 2)
        let input = SyntheticInput(hal, "mic")

        input.play(records([samples], layout: [2], rate: 48_000, frames: 480), pace: .realTime)
        await input.wait()
        await writer.finish()

        #expect(try readAudio(caf).samples == samples)
        let sidecar = try #require(Sidecar.decode(Data(contentsOf: folder.url.appending(path: "take1-1-1.sidecar"))))
        #expect(sidecar.checkpoints.map(\.fileFrame) == [0, 47_520])
        #expect(writer.droppedFrames == 0)
    }

    /// Control of criterion 2: a ring with room for about 0.16 s and a drain held for 0.3 s drop
    /// whole records, and the writer fills their frames with silence.
    @Test func aFullRingDropsWholeRecordsAndTheWriterFillsThemWithSilence() async throws {
        let hal = TestHAL([stereo])
        let writer = writer(hal, drainInterval: .milliseconds(300), ringSeconds: 0.1)
        let samples = sine(seconds: 1, rate: 48_000, channels: 2)
        let all = records([samples], layout: [2], rate: 48_000, frames: 480)
        let input = SyntheticInput(hal, "mic")

        input.play(Array(all[..<30]), pace: .ignoreRoom)
        await input.wait()
        await until(limit: .seconds(2), "the first drain did not come") { writer.droppedFrames > 0 }
        input.play(Array(all[30...]))
        await input.wait()
        await writer.finish()

        let dropped = writer.droppedFrames
        #expect(dropped > 0)
        #expect(dropped % 480 == 0)
        let written = try readAudio(caf).samples
        try #require(written.count == samples.count)
        var silent = 0
        for block in stride(from: 0, to: samples.count, by: 960) {
            let range = block..<min(block + 960, samples.count)
            if written[range].allSatisfy({ $0 == 0 }) {
                silent += 480
            } else {
                #expect(written[range] == samples[range], "block at \(block / 2)")
            }
        }
        #expect(silent == dropped)
    }

    /// A record without valid sample and host times ends the segment and is lost.
    @Test func aRecordWithoutValidTimesEndsTheSegment() async throws {
        let hal = TestHAL([stereo])
        let writer = writer(hal)
        let all = records([sine(seconds: 1, rate: 48_000, channels: 2)], layout: [2], rate: 48_000, frames: 480)
        let input = SyntheticInput(hal, "mic")

        input.play(Array(all[..<50]))
        await input.wait()
        input.play([all[50]], flags: [])
        await input.wait()
        input.play(Array(all[51...]))
        await input.wait()
        await writer.finish()

        #expect(try readAudio(caf).samples.count == 50 * 480 * 2)
        #expect(try readAudio(folder.url.appending(path: "take1-1-2.caf")).samples.count == 49 * 480 * 2)
    }

    /// Criterion 21 (a): the drain timer does not keep the writer after `finish()`.
    @Test func aFinishedWriterGoesAway() async throws {
        let hal = TestHAL([stereo])
        var writer: DeviceWriter? = writer(hal)
        weak let gone = writer
        let input = SyntheticInput(hal, "mic")
        input.play(records([sine(seconds: 0.1, rate: 48_000, channels: 2)], layout: [2], rate: 48_000))
        await input.wait()

        await writer?.finish()
        writer = nil

        await until("the writer is still alive after finish") { gone == nil }
    }
}

/// The wrap of the ring (criterion 3). Not on the main actor: it is CPU work that would hold
/// back the main-actor jobs of other tests.
struct CaptureRingWrapTests {
    /// 10,000 records of 1 to 4,096 frames with a seeded size, pushed while the ring has room and
    /// popped on the same thread, so records cross the end of the ring (criterion 3).
    func roundTrip(frames: (inout SeededGenerator) -> Int) {
        let ring = CaptureRing(capacity: 65_536, rate: 48_000)
        defer { ring.deallocate() }
        var generator = SeededGenerator(seed: 3)
        let pattern = (0..<16_384).map { _ in Float.random(in: -1...1, using: &generator) }
        func samples(_ count: Int) -> [Float] {
            let start = Int.random(in: 0...(pattern.count - count), using: &generator)
            return Array(pattern[start..<(start + count)])
        }
        var pending: [InputRecord] = []
        var checked = 0
        func popOne() {
            guard let popped = ring.pop() else { return }
            let expected = pending.removeFirst()
            let record = popped.record
            #expect(popped.frames == expected.frameCount)
            #expect(record?.sampleTime == expected.sampleTime)
            #expect(record?.hostTimeNanos == expected.hostTimeNanos)
            #expect(record?.nominalRate == expected.nominalRate)
            let same = record?.buffers == expected.buffers
            #expect(same, "the samples of record \(checked)")
            checked += 1
        }
        for index in 0..<10_000 {
            let count = frames(&generator)
            let record = InputRecord(
                sampleTime: Double(index * 4_096), hostTimeNanos: UInt64(index) * 1_000_000, frameCount: count,
                nominalRate: [44_100, 48_000][index % 2],
                buffers: [samples(2 * count), samples(count)])!
            while !withIOProcArguments(record, { ring.hasRoom(for: $1) }) { popOne() }
            send(record, to: ring)
            pending.append(record)
        }
        while !pending.isEmpty, checked < 10_000 { popOne() }
        #expect(checked == 10_000)
        #expect(ring.pop() == nil)
        #expect(ring.takeDroppedFrames() == 0)
    }

    /// 10 s at the nominal rate of the input channels, plus 25%, rounded up to a power of two,
    /// and at most 64 MiB. A higher available rate does not count.
    @Test(arguments: [
        (48_000.0, 1, 4_194_304),
        (48_000.0, 64, 67_108_864),
        (768_000.0, 64, 67_108_864),
        (8_000.0, 1, 524_288),
    ])
    func theRingIsSizedFromTheNominalRateWithACap(rate: Double, channels: Int, expected: Int) throws {
        let device = try #require(
            InputDevice(
                uid: "d", name: "D", nominalRate: rate, availableRates: [8_000...768_000],
                channelsPerBuffer: [channels], latency: 0))

        #expect(CaptureRing.capacity(for: device, seconds: 10) == expected)
    }

    @Test func recordsThatCrossTheEndReadBackEqual() {
        roundTrip { Int.random(in: 1...4_096, using: &$0) }
    }

    /// Control of criterion 3: records of 40 + 16 + 12 x 678 = 8,192 bytes divide the capacity,
    /// so they never cross the end. They read back equal too, so only the first test can show a
    /// wrap bug.
    @Test func recordsThatDivideTheCapacityReadBackEqual() {
        roundTrip { _ in 678 }
    }
}
