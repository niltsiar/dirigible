import Atomics
import DirigibleCore
import Foundation

/// The writer of one device (decisions 0004 and 0013). A drain timer on its serial queue pops
/// the ring of the current `DeviceInput`. It splits each record into the channels of each track
/// and writes one segment per track: a checkpoint at the first record, at the first record at or
/// after each further second of device frames, and at the last record, and a flush every 5 s of
/// device frames. A clock event closes the segments of every track, and the next record opens
/// new ones. All state is confined to its serial queue, so it is `@unchecked Sendable`.
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
    private let hal: DeviceHAL
    private let drainInterval: Duration
    private let ringSeconds: Double
    private let queue: DispatchQueue
    private var outputs: [Output]
    /// The open segment of every track, or nil between segments.
    private var segment: Segment?
    /// The number of the last segment that opened.
    private var segments = 0
    private var finished = false
    /// The attached appearance of the device and its detach.
    private var input: (input: DeviceInput, detach: Detach)?
    /// Inputs whose detach failed: a late IOProc call can still use their rings, so they stay.
    private var kept: [DeviceInput] = []
    private var timer: DispatchSourceTimer?
    private let dropped = ManagedAtomic<Int>(0)

    /// `tracks` holds the arm index and the 1-based device channels of each track. The start
    /// checks of `Studio` make every channel exist on the device. `drainInterval` and
    /// `ringSeconds` are parameters so that tests can make a ring overflow.
    init(
        device: InputDevice, tracks: [(arm: Int, channels: Route.Channels)], take: Int, folder: URL, hal: DeviceHAL,
        drainInterval: Duration = .milliseconds(50), ringSeconds: Double = 10
    ) {
        self.device = device
        self.take = take
        self.folder = folder
        self.hal = hal
        self.drainInterval = drainInterval
        self.ringSeconds = ringSeconds
        queue = DispatchQueue(label: "Dirigible.DeviceWriter.\(device.uid)")
        let channels = device.channelsPerBuffer.enumerated().flatMap { buffer, count in
            (0..<count).map { (buffer: buffer, channel: $0) }
        }
        outputs = tracks.map { track in
            Output(arm: track.arm, sources: track.channels.numbers.map { channels[$0 - 1] }, writer: nil)
        }
    }

    deinit { timer?.cancel() }

    /// The dropped frames of the take. Any thread can read it.
    var droppedFrames: Int { dropped.load(ordering: .relaxed) }

    /// Starts the drain timer, makes a `DeviceInput` with a new ring, and attaches it.
    func start() {
        queue.async { [self] in
            guard !finished, timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            let nanos = Int(drainInterval / .nanoseconds(1))
            timer.schedule(
                deadline: .now() + .nanoseconds(nanos), repeating: .nanoseconds(nanos), leeway: .nanoseconds(0))
            timer.setEventHandler { [weak self] in self?.drain() }
            timer.resume()
            self.timer = timer
            guard let found = hal.lookUp(device.uid) else { return }
            let input = DeviceInput(id: found.id, ring: CaptureRing(device: device, seconds: ringSeconds), writer: self)
            do {
                self.input = (input, try hal.attach(input))
            } catch {
                input.ring.deallocate()
            }
        }
    }

    /// Detaches, writes the rest of the ring, and closes every segment. A second call does
    /// nothing more.
    func finish() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                if !finished, let (input, detach) = input {
                    let clean = detach()
                    drain()
                    if clean { input.ring.deallocate() } else { kept.append(input) }
                    self.input = nil
                }
                endSegment()
                timer?.cancel()
                finished = true
                done.resume()
            }
        }
    }

    /// Writes each record in the ring. A record without valid times ends the segment.
    private func drain() {
        guard !finished, let ring = input?.input.ring else { return }
        while let popped = ring.pop() {
            if let record = popped.record { write(record) } else { endSegment() }
        }
        dropped.wrappingIncrement(by: ring.takeDroppedFrames(), ordering: .relaxed)
    }

    private func write(_ record: InputRecord) {
        guard !finished, record.frameCount > 0 else { return }
        // A byte-size mismatch closes the segment at the record, and the record is lost.
        guard record.buffers.count == device.channelsPerBuffer.count,
            zip(record.buffers, device.channelsPerBuffer).allSatisfy({ $0.count == record.frameCount * $1 })
        else { return endSegment() }
        if let segment, segment.breaks(at: record) { endSegment() }
        if segment == nil { open(at: record) }
        guard var current = segment else { return }

        // A forward jump of 2 s or less gets silence.
        let gap = Int((record.sampleTime - current.nextSampleTime).rounded())
        if gap > 0 {
            for index in outputs.indices {
                let silence = [Float](repeating: 0, count: gap * outputs[index].sources.count)
                write(index) { writer in try silence.withUnsafeBufferPointer { try writer.write($0, frames: gap) } }
            }
            current.fileFrame += Int64(gap)
        }

        let second = Int64(current.rate.rounded())
        let checkpoint = Checkpoint(
            fileFrame: current.fileFrame, sampleTime: record.sampleTime, hostTimeNanos: record.hostTimeNanos)
        current.lastWritten = current.fileFrame >= current.nextCheckpoint
        if current.lastWritten {
            each { try $0.checkpoint(checkpoint) }
            while current.nextCheckpoint <= current.fileFrame { current.nextCheckpoint += second }
        }
        current.last = checkpoint
        for index in outputs.indices {
            let sources = outputs[index].sources
            var samples = [Float](repeating: 0, count: record.frameCount * sources.count)
            for (position, source) in sources.enumerated() {
                let buffer = record.buffers[source.buffer]
                let width = device.channelsPerBuffer[source.buffer]
                for frame in 0..<record.frameCount {
                    samples[frame * sources.count + position] = buffer[frame * width + source.channel]
                }
            }
            write(index) { writer in
                try samples.withUnsafeBufferPointer { try writer.write($0, frames: record.frameCount) }
            }
        }
        current.fileFrame += Int64(record.frameCount)
        current.nextSampleTime = record.sampleTime + Double(record.frameCount)
        current.remember(record)
        if current.fileFrame >= current.nextFlush {
            each { try $0.flush() }
            current.nextFlush = current.fileFrame + 5 * second
        }
        segment = current
    }

    private func open(at record: InputRecord) {
        segments += 1
        segment = Segment(first: record)
        for index in outputs.indices {
            let header = CaptureHeader(
                deviceUID: device.uid, deviceName: device.name, nominalRate: record.nominalRate,
                availableRates: device.availableRates, channelCount: outputs[index].sources.count,
                latency: device.latency, firstSampleTime: record.sampleTime, firstHostTimeNanos: record.hostTimeNanos)
            let name = SegmentName(take: take, arm: outputs[index].arm, segment: segments)
            outputs[index].writer = try? SegmentWriter(folder: folder, name: name, header: header)
        }
    }

    /// Writes the checkpoint of the last record if the sidecar does not have it, and closes the
    /// segment of every track.
    private func endSegment() {
        guard let current = segment else { return }
        if let last = current.last, !current.lastWritten { each { try $0.checkpoint(last) } }
        each { try $0.close() }
        for index in outputs.indices { outputs[index].writer = nil }
        segment = nil
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

/// The clock state of one open segment, and the break rules of decision 0004.
private struct Segment {
    /// The sample time and the host time at the start of a record.
    struct Point {
        var sampleTime: Double
        var hostTimeNanos: UInt64
    }

    /// The header rate.
    let rate: Double
    let origin: Point
    /// The record starts of about the last 0.5 s. The first point is at least 0.5 s old when
    /// the segment is that long.
    var window: [Point] = []
    var nextSampleTime: Double
    /// Frames written to each segment so far.
    var fileFrame: Int64 = 0
    var nextCheckpoint: Int64 = 0
    var nextFlush: Int64
    /// The checkpoint of the last record, and whether the sidecar has it.
    var last: Checkpoint?
    var lastWritten = false

    static let windowNanos: Int64 = 500_000_000

    init(first record: InputRecord) {
        rate = record.nominalRate
        origin = Point(sampleTime: record.sampleTime, hostTimeNanos: record.hostTimeNanos)
        nextSampleTime = record.sampleTime
        nextFlush = 5 * Int64(record.nominalRate.rounded())
    }

    /// True when `record` starts a new segment: a new header rate, a backward sample-time jump,
    /// a forward jump of more than 2 s, or a slope change of more than 1%.
    func breaks(at record: InputRecord) -> Bool {
        let jump = record.sampleTime - nextSampleTime
        return record.nominalRate != rate || jump < 0 || jump > 2 * rate
            || slopeChanges(at: Point(sampleTime: record.sampleTime, hostTimeNanos: record.hostTimeNanos))
    }

    /// Compares the sample-time to host-time slope of the last 0.5 s with the two-point slope of
    /// the segment before that window. Both spans are 0.5 s or more, so a host-time jitter of
    /// 200 µs moves each slope by 0.08% at most.
    func slopeChanges(at point: Point) -> Bool {
        guard
            let start = window.last(where: {
                nanos(from: $0.hostTimeNanos, to: point.hostTimeNanos) >= Self.windowNanos
            })
        else { return false }
        let before = nanos(from: origin.hostTimeNanos, to: start.hostTimeNanos)
        guard before >= Self.windowNanos else { return false }
        let running = (start.sampleTime - origin.sampleTime) / Double(before)
        let recent =
            (point.sampleTime - start.sampleTime) / Double(nanos(from: start.hostTimeNanos, to: point.hostTimeNanos))
        return abs(recent / running - 1) > 0.01
    }

    mutating func remember(_ record: InputRecord) {
        let point = Point(sampleTime: record.sampleTime, hostTimeNanos: record.hostTimeNanos)
        window.append(point)
        while window.count > 1, nanos(from: window[1].hostTimeNanos, to: point.hostTimeNanos) >= Self.windowNanos {
            window.removeFirst()
        }
    }
}
