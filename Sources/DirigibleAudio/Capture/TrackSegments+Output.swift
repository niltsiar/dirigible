extension TrackSegments {
    struct Output {
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
        /// The short-term loudness of the track (decision 0033), at the rate of the records.
        var loudness: LoudnessMeter?
    }
}
