import AVFoundation
import CoreAudio
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Interleaved sine samples with amplitude 0.5. Channel `c` has the frequency
/// `frequency * (c + 1)`, so a test can tell the channels apart.
func sine(seconds: Double, rate: Double, channels: Int = 1, frequency: Double = 1000) -> [Float] {
    let frames = Int((seconds * rate).rounded())
    var samples = [Float](repeating: 0, count: frames * channels)
    for frame in 0..<frames {
        for channel in 0..<channels {
            let phase = 2 * Double.pi * frequency * Double(channel + 1) * Double(frame) / rate
            samples[frame * channels + channel] = Float(0.5 * sin(phase))
        }
    }
    return samples
}

/// A unique temporary folder, removed at deinit.
final class TemporaryFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "DirigibleAudioTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

/// SplitMix64: a small seeded generator, so a random test gives the same values on each run.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

/// The frames of an audio file as `AVAudioFile` reads them, interleaved. It reads in blocks: one
/// read of the whole length of an unclosed CAF gives fewer frames (probe 2026-09-24: 95232 of
/// 96000), and reads in blocks give all of them.
func readAudio(_ url: URL) throws -> (rate: Double, bits: Int?, samples: [Float]) {
    let file = try AVAudioFile(forReading: url)
    let channels = Int(file.processingFormat.channelCount)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
    var samples: [Float] = []
    samples.reserveCapacity(Int(file.length) * channels)
    while file.framePosition < file.length {
        try file.read(into: buffer)
        if buffer.frameLength == 0 { break }
        let data = try #require(buffer.floatChannelData)
        let frames = Int(buffer.frameLength)
        if channels == 1 {
            samples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: frames))
            continue
        }
        for frame in 0..<frames {
            for channel in 0..<channels { samples.append(data[channel][frame]) }
        }
    }
    return (file.fileFormat.sampleRate, file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int, samples)
}

/// The host time of the take start in the take packages: 1000 s after boot.
let takeStart: UInt64 = 1_000_000_000_000

/// A package with tracks and a `<recording>` in `session.xml`, and segments made by the real
/// `SegmentWriter`. It is removed at deinit.
final class TakePackage {
    let folder: TemporaryFolder
    let url: URL
    var capture: URL { url.appending(path: "Capture") }

    init(
        sampleRate: Int = 48_000, tracks: [(TrackID, ChannelLayout)] = [("t1", .mono)], take: Int = 1,
        playhead: Frames = 96_000
    ) throws {
        folder = try TemporaryFolder()
        url = folder.url.appending(path: "Show.dirigible")
        var session = Session(sampleRate: sampleRate)
        for (id, layout) in tracks { try session.addTrack(id, name: id.rawValue, layout: layout) }
        try session.setRecording(
            Recording(
                take: take, playheadFrame: playhead, takeStartHostTimeNanos: takeStart,
                armedTracks: tracks.map(\.0)))
        try session.write(to: url)
        try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
    }

    func read() throws -> Session { try Session(contentsOf: url) }

    static func header(
        rate: Double = 48_000, channels: Int = 1, latency: Int = 48, firstHost: UInt64 = takeStart + 10_000_000
    ) -> CaptureHeader {
        CaptureHeader(
            deviceUID: "usb-1", deviceName: "USB Mic", nominalRate: rate, availableRates: [rate...rate],
            channelCount: channels, latency: latency, firstSampleTime: 512, firstHostTimeNanos: firstHost)
    }

    /// Checkpoints at frame 0, at each whole second, and at the last frame, on a clock that runs
    /// at `realRate` (default: the header rate).
    static func checkpoints(frames: Int, header: CaptureHeader, realRate: Double? = nil) -> [Checkpoint] {
        let rate = realRate ?? header.nominalRate
        let second = Int(rate.rounded())
        return (Array(stride(from: 0, to: frames, by: second)) + [frames - 1]).map { frame in
            Checkpoint(
                fileFrame: Int64(frame), sampleTime: header.firstSampleTime + Double(frame),
                hostTimeNanos: header.firstHostTimeNanos + UInt64((Double(frame) / rate * 1e9).rounded()))
        }
    }

    /// Writes one segment with the real writer. It closes the writer unless `open` is true; the
    /// caller then keeps the returned writer alive as a crashed process.
    @discardableResult
    func segment(
        take: Int = 1, arm: Int = 1, segment: Int = 1, header: CaptureHeader = TakePackage.header(), samples: [Float],
        checkpoints: [Checkpoint]? = nil, open: Bool = false
    ) throws -> SegmentWriter {
        let frames = samples.count / header.channelCount
        let writer = try SegmentWriter(
            folder: capture, name: SegmentName(take: take, arm: arm, segment: segment), header: header)
        for checkpoint in checkpoints ?? Self.checkpoints(frames: frames, header: header) {
            try writer.checkpoint(checkpoint)
        }
        try samples.withUnsafeBufferPointer { try writer.write($0, frames: frames) }
        if !open { try writer.close() }
        return writer
    }
}

/// Records of `frames` frames from interleaved samples. `buffers[i]` holds the samples of buffer
/// `i` with `layout[i]` channels. The host time runs at `rate` from `hostStart`.
func records(
    _ buffers: [[Float]], layout: [Int], rate: Double, frames: Int = 512, sampleStart: Double = 0,
    hostStart: UInt64 = takeStart
) -> [InputRecord] {
    let total = buffers[0].count / layout[0]
    return stride(from: 0, to: total, by: frames).map { start in
        let count = min(frames, total - start)
        return InputRecord(
            sampleTime: sampleStart + Double(start), hostTimeNanos: hostStart + UInt64(Double(start) / rate * 1e9),
            frameCount: count, nominalRate: rate,
            buffers: zip(buffers, layout).map { buffer, channels in
                Array(buffer[(start * channels)..<((start + count) * channels)])
            })!
    }
}

/// Polls `condition` every 10 ms. After `limit`, it records `message` as a test failure.
@MainActor
func until(limit: Duration = .seconds(1), _ message: String, _ condition: () -> Bool) async {
    let end = ContinuousClock.now + limit
    while !condition() {
        guard ContinuousClock.now < end else {
            Issue.record("\(message) (limit \(limit))")
            return
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

/// The sample and host times of a HAL call that are valid.
let validTimes: AudioTimeStampFlags = [.sampleTimeValid, .hostTimeValid]

/// Makes the `AudioBufferList` and the `AudioTimeStamp` of one IOProc call from `record`. The
/// channel count of buffer `i` is `buffers[i].count / frameCount`.
func withIOProcArguments<Result>(
    _ record: InputRecord, flags: AudioTimeStampFlags = validTimes,
    _ body: (UnsafePointer<AudioTimeStamp>, UnsafePointer<AudioBufferList>) -> Result
) -> Result {
    let list = AudioBufferList.allocate(maximumBuffers: record.buffers.count)
    var data: [UnsafeMutablePointer<Float>] = []
    defer {
        for pointer in data { pointer.deallocate() }
        free(list.unsafeMutablePointer)
    }
    for (index, samples) in record.buffers.enumerated() {
        let pointer = UnsafeMutablePointer<Float>.allocate(capacity: max(1, samples.count))
        pointer.initialize(from: samples, count: samples.count)
        data.append(pointer)
        list[index] = AudioBuffer(
            mNumberChannels: UInt32(samples.count / max(1, record.frameCount)),
            mDataByteSize: UInt32(samples.count * 4), mData: pointer)
    }
    var time = AudioTimeStamp()
    time.mSampleTime = record.sampleTime
    time.mHostTime = AudioConvertNanosToHostTime(record.hostTimeNanos)
    time.mRateScalar = 1
    time.mFlags = flags
    return body(&time, list.unsafePointer)
}

/// Calls `CaptureRing.ioProc` once, as the HAL does, after the rate listener effect.
func send(_ record: InputRecord, to ring: CaptureRing, flags: AudioTimeStampFlags = validTimes) {
    ring.setRate(record.nominalRate)
    withIOProcArguments(record, flags: flags) { time, list in
        var output = AudioBufferList()
        _ = CaptureRing.ioProc(1, time, list, time, &output, time, ring.context)
    }
}

/// The test `DeviceHAL` (plan slice 1): a device set, the inputs of each attach, and the
/// producers that a clean detach stops. Object IDs start at 1 in the order of `devices`.
final class TestHAL: @unchecked Sendable {
    private let lock = NSLock()
    private var present: [String: (id: AudioObjectID, device: InputDevice)] = [:]
    private var attached: [String: [DeviceInput]] = [:]
    private var producers: [String: SyntheticInput] = [:]

    init(_ devices: [InputDevice]) {
        for (index, device) in devices.enumerated() { present[device.uid] = (AudioObjectID(index + 1), device) }
    }

    var hal: DeviceHAL {
        DeviceHAL(
            lookUp: { [self] uid in lock.withLock { present[uid] } },
            attach: { [self] input throws(HALError) in
                let uid = lock.withLock {
                    let uid = present.first { $0.value.id == input.id }!.key
                    attached[uid, default: []].append(input)
                    return uid
                }
                return { [self] in
                    lock.withLock { producers[uid] }?.stop()
                    return true
                }
            })
    }

    /// The inputs of each attach of `uid`, in order.
    func inputs(_ uid: String) -> [DeviceInput] { lock.withLock { attached[uid] ?? [] } }

    func register(_ producer: SyntheticInput, for uid: String) { lock.withLock { producers[uid] = producer } }
}

/// A `Thread` that calls `CaptureRing.ioProc` with records, into the ring of the last attach of
/// its device. It waits for that attach. Real-time pace sends one record each 10 ms; burst mode
/// sends as fast as the ring has room; `ignoreRoom` sends at once and lets a full ring drop.
final class SyntheticInput: @unchecked Sendable {
    enum Pace { case realTime, burst, ignoreRoom }

    let hal: TestHAL
    let uid: String
    private let lock = NSLock()
    private var stopped = false
    private var done: DispatchSemaphore?

    init(_ hal: TestHAL, _ uid: String) {
        self.hal = hal
        self.uid = uid
        hal.register(self, for: uid)
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    func play(_ records: [InputRecord], pace: Pace = .burst, flags: AudioTimeStampFlags = validTimes) {
        let done = DispatchSemaphore(value: 0)
        lock.withLock {
            stopped = false
            self.done = done
        }
        Thread { [self] in
            send(records, pace: pace, flags: flags)
            done.signal()
        }.start()
    }

    /// Waits until the records of the last `play` are sent, with a limit.
    func wait(limit: Double = 10) {
        guard let done = lock.withLock({ done }) else { return }
        if done.wait(timeout: .now() + limit) == .timedOut {
            Issue.record("SyntheticInput \(uid) did not end in \(limit) s")
        } else {
            done.signal()  // A later wait or stop returns at once.
        }
    }

    /// Stops the sends and waits for the thread, with a limit of 1 s. The test detach calls it.
    func stop() {
        guard
            let done = lock.withLock({ () -> DispatchSemaphore? in
                stopped = true
                return self.done
            })
        else { return }
        if done.wait(timeout: .now() + 1) == .timedOut {
            Issue.record("SyntheticInput \(uid) did not stop in 1 s")
        } else {
            done.signal()
        }
    }

    private func send(_ records: [InputRecord], pace: Pace, flags: AudioTimeStampFlags) {
        let end = Date.now + 10
        var input = hal.inputs(uid).last
        while input == nil, Date.now < end, !isStopped {
            usleep(1000)
            input = hal.inputs(uid).last
        }
        guard let input else { return }
        let start = Date.now
        for (index, record) in records.enumerated() {
            if isStopped { return }
            if pace == .realTime {
                let delay = start.addingTimeInterval(Double(index) / 100).timeIntervalSinceNow
                if delay > 0 { usleep(UInt32(delay * 1e6)) }
            }
            input.ring.setRate(record.nominalRate)
            withIOProcArguments(record, flags: flags) { time, list in
                let full = Date.now
                while pace != .ignoreRoom, !input.ring.hasRoom(for: list) {
                    guard !isStopped, Date.now < full + 10 else { return }
                    usleep(500)
                }
                var output = AudioBufferList()
                _ = CaptureRing.ioProc(input.id, time, list, time, &output, time, input.ring.context)
            }
        }
    }
}
