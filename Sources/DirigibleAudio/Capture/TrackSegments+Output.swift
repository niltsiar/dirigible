import DirigibleCore

extension TrackSegments {
    struct Output {
        let arm: Int
        /// The 1-based device channels of the track.
        let channels: [Int]
        /// (buffer index, channel index in the buffer) of each track channel.
        var sources: [(buffer: Int, channel: Int)] = []
        var writer: SegmentWriter?
        /// The frames for `writer` that are not in its file yet. An output with no writer holds
        /// no frame.
        var held = HeldFrames()
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
        /// The short-term loudness of the track (decision 0033), at the rate of the records.
        var loudness: LoudnessMeter?
    }

    /// The interleaved frames of one output that its file does not hold yet, and their host
    /// span. The three fields change together, through `add` and `clear` only.
    struct HeldFrames {
        private(set) var samples: [Float] = []
        private(set) var frames = 0
        private(set) var span: (start: UInt64, end: UInt64)?

        /// Adds `frames` interleaved frames from host time `start` to `end`.
        mutating func add(_ samples: [Float], frames: Int, from start: UInt64, to end: UInt64) {
            self.samples.append(contentsOf: samples)
            self.frames += frames
            span = TrackSegments.union(span, start, end)
        }

        mutating func clear() {
            samples.removeAll(keepingCapacity: true)
            frames = 0
            span = nil
        }
    }

    /// `span` with `start..<end`: the smallest start and the largest end by the signed
    /// `nanos(from:to:)`, so the order of the host times does not matter.
    static func union(_ span: (start: UInt64, end: UInt64)?, _ start: UInt64, _ end: UInt64) -> (
        start: UInt64, end: UInt64
    ) {
        guard let span else { return (start, end) }
        return (
            nanos(from: span.start, to: start) < 0 ? start : span.start,
            nanos(from: span.end, to: end) > 0 ? end : span.end
        )
    }

    /// Writes the held frames of every track with one append for each file. The drain calls it
    /// after its last record.
    mutating func commit() {
        for index in outputs.indices { commit(index) }
    }

    /// Appends the held frames of output `index`. Only a whole append gives them a span and
    /// clears them; after a write error, `fail` clears them, so none counts as written.
    mutating func commit(_ index: Int) {
        let held = outputs[index].held
        guard held.frames > 0 else { return }
        let wrote = write(index) { writer in
            try held.samples.withUnsafeBufferPointer { try writer.write($0, frames: held.frames) }
        }
        guard wrote else { return }
        if let span = held.span { extend(index, from: span.start, to: span.end) }
        outputs[index].held.clear()
    }
}
