import DirigibleCore
import Foundation

/// The take of a device writer: its number, and the `Capture/` folder when a segment opens. The
/// package can move during a take (decision 0014), so the folder is a closure.
struct TakeFiles: Sendable {
    let take: Int
    let folder: @Sendable () throws(SessionFileError) -> URL
}

/// The segment files of the tracks of one device for a take (decisions 0004, 0012, and 0013).
/// It splits each record into the channels of each track and writes one segment per track: a
/// checkpoint at the first record, at the first record at or after each further second of device
/// frames, and at the last record, and a flush every 5 s of device frames. A clock event closes
/// the segments of every track, and the next record opens new ones. A write error closes the
/// segment of one track, and that track opens its next segment number after 1 s of device frames.
/// With no take files, it is a monitor (decision 0015): it computes the peaks and opens no
/// segment. Its `DeviceWriter` uses it on the writer queue only.
struct TrackSegments {
    private struct Output {
        let arm: Int
        /// The 1-based device channels of the track.
        let channels: [Int]
        /// (buffer index, channel index in the buffer) of each track channel.
        var sources: [(buffer: Int, channel: Int)] = []
        var writer: SegmentWriter?
        /// The device segment frame of the first frame of `writer`: 0, or the frame of a reopen.
        var offset: Int64 = 0
        /// The file frame of the last checkpoint in the sidecar of `writer`.
        var checkpointed: Int64?
        /// The device frame of the last write or open error. Nil when the track has no error.
        var failedAt: Int64?
        /// The largest absolute sample and the largest 256-frame block RMS since the last
        /// `takeLevels`. A track with a write error still gets them: the device is alive.
        var peak: Float = 0
        var rms: Float = 0
        /// The raw host nanoseconds of the frames that `writer` wrote since the last
        /// `takeLevels`. The bounds stay apart until `takeLevels`, so no `Range` traps.
        var written: (start: UInt64, end: UInt64)?
        /// True after a write error, or after a segment that opens after a host hole, since the
        /// last `takeLevels`. Then the later frames of the drain get no span, so it holds no gap.
        var spanStopped = false
    }

    /// A gap of more than 1 ms before a new segment is a hole. The jitter of a host time is
    /// 200 µs or less (`Segment`), and a hole is more than 2 s.
    private static let holeNanos: Int64 = 1_000_000

    /// Nil for a monitor.
    private let files: TakeFiles?
    private let report: @Sendable (Report) -> Void
    /// The device layout of the next records.
    private(set) var device: InputDevice
    private var outputs: [Output]
    /// The open segment of every track, or nil between segments.
    private var segment: Segment?
    /// The number of the last segment that opened, for any track.
    private var segments = 0
    /// The device frames of the take that the writer handled: records and silence.
    private var deviceFrames: Int64 = 0
    /// The cause of the first gap of each arm.
    var gaps: [Int: TakeResult.Gap] = [:]

    init(
        device: InputDevice, tracks: [(arm: Int, channels: Route.Channels)], files: TakeFiles?,
        report: @escaping @Sendable (Report) -> Void
    ) {
        self.device = device
        self.files = files
        self.report = report
        outputs = tracks.map { Output(arm: $0.arm, channels: $0.channels.numbers) }
        use(device)
    }

    var arms: [Int] { outputs.map(\.arm) }

    /// The take number of the reports: 0 for a monitor.
    var take: Int { files?.take ?? 0 }

    /// The 24-bit WAV bytes of every track for the device frames so far. ponytail: it counts
    /// a track with an error too, so the disk rule stops a little early.
    var wavBytes: Int64 { deviceFrames * Int64(outputs.reduce(0) { $0 + $1.channels.count }) * 3 }

    func hasRoutedChannels(_ device: InputDevice) -> Bool {
        outputs.allSatisfy { $0.channels.allSatisfy { $0 <= device.channelCount } }
    }

    /// Takes `channels` (the channel count of each buffer) as the layout of the next records.
    /// False, with no change, when a routed channel is not in it.
    mutating func use(channels: [Int]) -> Bool {
        guard
            let changed = InputDevice(
                uid: device.uid, name: device.name, nominalRate: device.nominalRate,
                availableRates: device.availableRates, channelsPerBuffer: channels, latency: device.latency),
            hasRoutedChannels(changed)
        else { return false }
        use(changed)
        return true
    }

    /// Takes the layout of `device` for the next records.
    mutating func use(_ device: InputDevice) {
        self.device = device
        let channels = device.channelsPerBuffer.enumerated().flatMap { buffer, count in
            (0..<count).map { (buffer: buffer, channel: $0) }
        }
        for index in outputs.indices { outputs[index].sources = outputs[index].channels.map { channels[$0 - 1] } }
    }

    /// Writes `record`. False when it drops the record: its byte sizes do not match its layout,
    /// or its layout has no routed channel. A record of a new layout ends the segment, and the
    /// tracks take its layout.
    mutating func write(_ record: InputRecord) -> Bool {
        guard record.frameCount > 0 else { return true }
        let layout = record.channelsPerBuffer
        guard zip(record.buffers, layout).allSatisfy({ $0.count == record.frameCount * $1 }) else {
            endSegment()
            return false
        }
        if layout != device.channelsPerBuffer {
            endSegment()
            guard use(channels: layout) else { return false }
        }
        // A monitor writes no file.
        guard files != nil else {
            for index in outputs.indices { _ = samples(index, of: record) }
            return true
        }
        if let segment, segment.breaks(at: record) { endSegment() }
        if segment == nil { open(at: record) }
        guard var current = segment else { return true }

        // A forward jump of 2 s or less gets silence. The file holds the silence, so the span
        // takes it too.
        let gap = Int((record.sampleTime - current.nextSampleTime).rounded())
        if gap > 0 {
            let silenceStart = record.hostTimeNanos &- Self.nanoseconds(frames: gap, rate: current.rate)
            for index in outputs.indices {
                let silence = [Float](repeating: 0, count: gap * outputs[index].sources.count)
                let filled = write(index) { writer in
                    try silence.withUnsafeBufferPointer { try writer.write($0, frames: gap) }
                }
                if filled { extend(index, from: silenceStart, to: record.hostTimeNanos) }
            }
            current.fileFrame += Int64(gap)
            deviceFrames += Int64(gap)
        }

        let second = Int64(current.rate.rounded())
        // A track with an error opens its next segment after 1 s of device frames.
        for index in outputs.indices {
            guard let failed = outputs[index].failedAt, deviceFrames - failed >= second else { continue }
            if open(index, at: record, fileFrame: current.fileFrame) {
                report(.state(take: take, arm: outputs[index].arm, .recording, status: nil))
            }
        }
        let checkpoint = Checkpoint(
            fileFrame: current.fileFrame, sampleTime: record.sampleTime, hostTimeNanos: record.hostTimeNanos)
        let due = current.fileFrame >= current.nextCheckpoint
        for index in outputs.indices where outputs[index].writer != nil && (due || outputs[index].checkpointed == nil) {
            self.checkpoint(index, checkpoint)
        }
        while current.nextCheckpoint <= current.fileFrame { current.nextCheckpoint += second }
        current.last = checkpoint
        let end = record.hostTimeNanos &+ Self.nanoseconds(frames: record.frameCount, rate: record.nominalRate)
        for index in outputs.indices {
            let samples = samples(index, of: record)
            let wrote = write(index) { writer in
                try samples.withUnsafeBufferPointer { try writer.write($0, frames: record.frameCount) }
            }
            if wrote { extend(index, from: record.hostTimeNanos, to: end) }
        }
        current.fileFrame += Int64(record.frameCount)
        deviceFrames += Int64(record.frameCount)
        current.nextSampleTime = record.sampleTime + Double(record.frameCount)
        current.remember(record)
        if current.fileFrame >= current.nextFlush {
            each { try $0.flush() }
            current.nextFlush = current.fileFrame + 5 * second
        }
        segment = current
        return true
    }

    /// The interleaved samples of the track of output `index` in `record`. It also takes them into
    /// the peak and the RMS of the arm.
    private mutating func samples(_ index: Int, of record: InputRecord) -> [Float] {
        let sources = outputs[index].sources
        var samples = [Float](repeating: 0, count: record.frameCount * sources.count)
        for (position, source) in sources.enumerated() {
            let buffer = record.buffers[source.buffer]
            let width = device.channelsPerBuffer[source.buffer]
            for frame in 0..<record.frameCount {
                samples[frame * sources.count + position] = buffer[frame * width + source.channel]
            }
        }
        outputs[index].peak = samples.reduce(outputs[index].peak) { max($0, abs($1)) }
        // The block of level 0 of `Peaks`.
        let block = Peaks.binFrames[0] * sources.count
        for start in stride(from: 0, to: samples.count, by: block) {
            let part = samples[start..<min(start + block, samples.count)]
            let rms = (part.reduce(0) { $0 + $1 * $1 } / Float(part.count)).squareRoot()
            outputs[index].rms = max(outputs[index].rms, rms)
        }
        return samples
    }

    /// The nanoseconds of `frames` at `rate`.
    private static func nanoseconds(frames: Int, rate: Double) -> UInt64 {
        UInt64((Double(frames) * 1e9 / rate).rounded())
    }

    /// Adds the host span `start..<end`, which the writer of output `index` wrote, to the span of
    /// its arm. The span keeps the smallest start and the largest end by the signed
    /// `nanos(from:to:)`, so the order of the host times does not matter.
    private mutating func extend(_ index: Int, from start: UInt64, to end: UInt64) {
        guard !outputs[index].spanStopped else { return }
        guard let span = outputs[index].written else {
            outputs[index].written = (start, end)
            return
        }
        outputs[index].written = (
            nanos(from: span.start, to: start) < 0 ? start : span.start,
            nanos(from: span.end, to: end) > 0 ? end : span.end
        )
    }

    /// The device latency in nanoseconds at the nominal rate. It is signed and holds no host time.
    var latencyNanos: Int64 { Int64((Double(device.latency) * 1e9 / device.nominalRate).rounded()) }

    /// The level of each arm since the last call, and a new start.
    mutating func takeLevels() -> [Int: ArmLevel] {
        defer {
            for index in outputs.indices {
                outputs[index].peak = 0
                outputs[index].rms = 0
                outputs[index].written = nil
                outputs[index].spanStopped = false
            }
        }
        return Dictionary(
            uniqueKeysWithValues: outputs.map {
                ($0.arm, ArmLevel(peak: $0.peak, rms: $0.rms, written: Self.range($0.written)))
            })
    }

    /// Nil when there is no span or its end is not after its start, so no `Range` traps.
    private static func range(_ span: (start: UInt64, end: UInt64)?) -> Range<UInt64>? {
        guard let span, span.end > span.start else { return nil }
        return span.start..<span.end
    }

    /// Opens a segment for every track that has no error. A track with an error waits for its
    /// 1 s of device frames.
    private mutating func open(at record: InputRecord) {
        // No file holds the frames of a host hole before the new segment.
        for index in outputs.indices {
            guard let span = outputs[index].written else { continue }
            if nanos(from: span.end, to: record.hostTimeNanos) > Self.holeNanos { outputs[index].spanStopped = true }
        }
        segments += 1
        segment = Segment(first: record)
        for index in outputs.indices where outputs[index].failedAt == nil {
            open(index, at: record, fileFrame: 0, number: segments)
        }
    }

    /// Opens the next segment number for the track of output `index`, whose file starts at
    /// `fileFrame` of the device segment. An open error is a write error.
    @discardableResult
    private mutating func open(_ index: Int, at record: InputRecord, fileFrame: Int64, number: Int? = nil) -> Bool {
        // `write` opens no segment for a monitor.
        guard let files else { return false }
        if number == nil { segments += 1 }
        let header = CaptureHeader(
            deviceUID: device.uid, deviceName: device.name, nominalRate: record.nominalRate,
            availableRates: device.availableRates, channelCount: outputs[index].sources.count,
            latency: device.latency, firstSampleTime: record.sampleTime, firstHostTimeNanos: record.hostTimeNanos)
        let name = SegmentName(take: take, arm: outputs[index].arm, segment: number ?? segments)
        let capture: URL
        do throws(SessionFileError) {
            capture = try files.folder()
        } catch {
            // The package left its volume: the track gets a write error.
            fail(index, status: ENOENT)
            return false
        }
        do {
            outputs[index].writer = try SegmentWriter(folder: capture, name: name, header: header)
        } catch {
            fail(index, status: error.status)
            return false
        }
        outputs[index].offset = fileFrame
        outputs[index].checkpointed = nil
        outputs[index].failedAt = nil
        return true
    }

    /// Writes `checkpoint` of the device segment to the sidecar of output `index`, at its file
    /// frame.
    private mutating func checkpoint(_ index: Int, _ checkpoint: Checkpoint) {
        let frame = checkpoint.fileFrame - outputs[index].offset
        write(index) { writer in
            try writer.checkpoint(
                Checkpoint(fileFrame: frame, sampleTime: checkpoint.sampleTime, hostTimeNanos: checkpoint.hostTimeNanos)
            )
        }
        outputs[index].checkpointed = frame
    }

    /// Writes the checkpoint of the last record where the sidecar does not have it, and closes
    /// the segment of every track.
    mutating func endSegment() {
        guard let current = segment else { return }
        for index in outputs.indices {
            guard let last = current.last, outputs[index].writer != nil,
                outputs[index].checkpointed != last.fileFrame - outputs[index].offset
            else { continue }
            checkpoint(index, last)
        }
        each { try $0.close() }
        for index in outputs.indices { outputs[index].writer = nil }
        segment = nil
    }

    private mutating func each(_ body: (SegmentWriter) throws -> Void) {
        for index in outputs.indices { write(index, body) }
    }

    /// Runs `body` on the segment of output `index`. A write error closes that segment; the
    /// frames on disk stay. True when `body` ran with no error.
    @discardableResult
    private mutating func write(_ index: Int, _ body: (SegmentWriter) throws -> Void) -> Bool {
        guard let writer = outputs[index].writer else { return false }
        do {
            try body(writer)
            return true
        } catch {
            try? writer.close()
            fail(index, status: (error as? CaptureError)?.status ?? 0)
            return false
        }
    }

    /// The track of output `index` has no segment until 1 s of device frames from now: report
    /// `.writeFailed` with the raw status, and record the gap.
    private mutating func fail(_ index: Int, status: Int32) {
        outputs[index].writer = nil
        outputs[index].failedAt = deviceFrames
        outputs[index].spanStopped = true
        let arm = outputs[index].arm
        gaps[arm] = gaps[arm] ?? .writeFailed
        report(.state(take: take, arm: arm, .writeFailed, status: status))
    }
}
