import DirigibleCore
import Foundation

/// The writer of one device (decision 0004). It splits each record into the channels of each
/// track and writes one segment per track: a checkpoint at the first record, at the first record
/// at or after each further second of device frames, and at the last record, and a flush every
/// 5 s of device frames. All state is confined to its serial queue, so it is `@unchecked
/// Sendable`. In this run each track has one segment; the clock events that start a new segment
/// come with slice 8.
final class DeviceWriter: @unchecked Sendable {
    private struct Output {
        let arm: Int
        /// (buffer index, channel index in the buffer) of each track channel.
        let sources: [(buffer: Int, channel: Int)]
        var writer: SegmentWriter?
    }

    private let device: InputDevice
    private let take: Int
    private let folder: URL
    private let queue: DispatchQueue
    private var outputs: [Output]
    private var opened = false
    private var finished = false
    /// Frames written to each segment so far.
    private var fileFrame: Int64 = 0
    private var nextCheckpoint: Int64 = 0
    private var nextFlush: Int64 = 0
    /// The checkpoint of the last record, and whether the sidecar has it.
    private var last: Checkpoint?
    private var lastWritten = false

    /// `tracks` holds the arm index and the 1-based device channels of each track. The start
    /// checks of `Studio` make every channel exist on the device.
    init(device: InputDevice, tracks: [(arm: Int, channels: Route.Channels)], take: Int, folder: URL) {
        self.device = device
        self.take = take
        self.folder = folder
        queue = DispatchQueue(label: "Dirigible.DeviceWriter.\(device.uid)")
        let channels = device.channelsPerBuffer.enumerated().flatMap { buffer, count in
            (0..<count).map { (buffer: buffer, channel: $0) }
        }
        outputs = tracks.map { track in
            Output(arm: track.arm, sources: track.channels.numbers.map { channels[$0 - 1] }, writer: nil)
        }
    }

    /// Queues the record. It never blocks the caller.
    func append(_ record: InputRecord) {
        queue.async { self.write(record) }
    }

    /// Writes the queued records and closes every segment. A second call does nothing more.
    func finish() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async {
                self.close()
                done.resume()
            }
        }
    }

    private func write(_ record: InputRecord) {
        // ponytail: a record that does not match the device layout is dropped; slice 8 starts a
        // new segment at it.
        guard !finished, record.frameCount > 0, record.buffers.count == device.channelsPerBuffer.count,
            zip(record.buffers, device.channelsPerBuffer).allSatisfy({ $0.count == record.frameCount * $1 })
        else { return }
        if !opened { open(at: record) }
        let second = Int64(record.nominalRate.rounded())
        let checkpoint = Checkpoint(
            fileFrame: fileFrame, sampleTime: record.sampleTime, hostTimeNanos: record.hostTimeNanos)
        lastWritten = fileFrame >= nextCheckpoint
        if lastWritten {
            each { try $0.checkpoint(checkpoint) }
            while nextCheckpoint <= fileFrame { nextCheckpoint += second }
        }
        last = checkpoint
        for index in outputs.indices {
            let sources = outputs[index].sources
            var samples = [Float](repeating: 0, count: record.frameCount * sources.count)
            for frame in 0..<record.frameCount {
                for (position, source) in sources.enumerated() {
                    let width = device.channelsPerBuffer[source.buffer]
                    samples[frame * sources.count + position] =
                        record.buffers[source.buffer][frame * width + source.channel]
                }
            }
            write(index) { writer in
                try samples.withUnsafeBufferPointer { try writer.write($0, frames: record.frameCount) }
            }
        }
        fileFrame += Int64(record.frameCount)
        if fileFrame >= nextFlush {
            each { try $0.flush() }
            nextFlush = fileFrame + 5 * second
        }
    }

    private func open(at record: InputRecord) {
        opened = true
        nextFlush = 5 * Int64(record.nominalRate.rounded())
        for index in outputs.indices {
            let header = CaptureHeader(
                deviceUID: device.uid, deviceName: device.name, nominalRate: record.nominalRate,
                availableRates: device.availableRates, channelCount: outputs[index].sources.count,
                latency: device.latency, firstSampleTime: record.sampleTime, firstHostTimeNanos: record.hostTimeNanos)
            let name = SegmentName(take: take, arm: outputs[index].arm, segment: 1)
            outputs[index].writer = try? SegmentWriter(folder: folder, name: name, header: header)
        }
    }

    private func close() {
        guard !finished else { return }
        finished = true
        if let last, !lastWritten { each { try $0.checkpoint(last) } }
        each { try $0.close() }
    }

    private func each(_ body: (SegmentWriter) throws -> Void) {
        for index in outputs.indices { write(index, body) }
    }

    /// Runs `body` on the segment of output `index`. A write error closes that segment; the
    /// frames on disk stay. ponytail: capture-live shows the error in the UI.
    private func write(_ index: Int, _ body: (SegmentWriter) throws -> Void) {
        guard let writer = outputs[index].writer else { return }
        do {
            try body(writer)
        } catch {
            try? writer.close()
            outputs[index].writer = nil
        }
    }
}
