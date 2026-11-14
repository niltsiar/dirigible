import DirigibleCore

/// The bins of one track of a take in progress (live take view). Live frame 0 is the take start:
/// the host time `startHostNanos` and the session frame `origin`. A bin holds the largest peak
/// and the largest RMS of the written spans that touch its `rate / 20` frames (50 ms). The final
/// peaks of the WAV replace these bins when they are ready (decision 0017).
public struct LivePeaks: Sendable {
    /// `add` refuses a span that ends more than this many nanoseconds after its `now`, so a bad
    /// device time cannot grow the bins without a limit.
    static let futureLimit: Int64 = 5_000_000_000

    /// The session frame of live frame 0: the playhead of the take.
    public let origin: Frames
    let startHostNanos: UInt64
    let rate: Int
    let binFrames: Int
    private(set) var bins: [PeakColumn] = []
    /// The live frames that the spans cover, in order. Spans with a gap under one bin merge: the
    /// rounding of the drain ends gives such gaps, and a draw walks each range. A real gap (a lost
    /// device, a write error) is at least one drain of 50 ms, so it stays.
    public private(set) var covered: [Range<Frames>] = []
    /// The lowest live frame whose draw an add changed since the view cleared it (F1): the start
    /// of the lowest bin that it touched, or the end of the covered range before its span. The
    /// box goes from that end to the head, so a span after a gap changes the gap to the lane color.
    var addedFrom: Frames?

    init(origin: Frames, startHostNanos: UInt64, rate: Int) {
        self.origin = origin
        self.startHostNanos = startHostNanos
        self.rate = rate
        binFrames = rate / 20
    }

    /// Adds the level of one written host span (`ArmLevel.written`, no latency). The latency
    /// moves the span earlier at the frame conversion, as the finalize does. Only the part at
    /// or after frame 0 is written. Returns false when it writes nothing.
    @discardableResult
    mutating func add(peak: Float, rms: Float, span: Range<UInt64>, latencyNanos: Int64, now: UInt64) -> Bool {
        guard nanos(from: now, to: span.upperBound) <= Self.futureLimit else { return false }
        let first = frame(span.lowerBound, latencyNanos)
        let end = frame(span.upperBound, latencyNanos)
        let lower = max(first, 0)
        let upper = end
        guard upper > lower else { return false }
        let low = lower / binFrames
        let high = (upper + binFrames - 1) / binFrames
        if bins.count < high { bins.append(contentsOf: repeatElement(.zero, count: high - bins.count)) }
        let column = PeakColumn(peak32: quantize(peak), rms32: quantize(rms))
        for bin in low..<high {
            bins[bin] = PeakColumn(peak32: max(bins[bin].peak, column.peak), rms32: max(bins[bin].rms, column.rms))
        }
        let before = covered.last { $0.lowerBound <= Frames(lower) }?.upperBound ?? .zero
        cover(Frames(lower)..<Frames(upper))
        addedFrom = min(addedFrom ?? .limit, Frames(low * binFrames), before)
        return true
    }

    /// The contract of `Peaks.fill`, in live frames: each column takes the largest bin that it
    /// touches. A column after the last bin gets zero.
    public func fill(_ columns: inout [PeakColumn], from: Double, step: Double) {
        fillColumns(
            &columns, from: from, step: step, bins: bins, bin: Double(binFrames), end: Double(bins.count * binFrames))
    }

    /// The live frame of a host time, with the signed difference, so a time before the take
    /// start gives a negative frame and no trap.
    private func frame(_ host: UInt64, _ latencyNanos: Int64) -> Int {
        Int(((Double(nanos(from: startHostNanos, to: host)) - Double(latencyNanos)) * Double(rate) / 1e9).rounded())
    }

    private mutating func cover(_ span: Range<Frames>) {
        var lower = span.lowerBound
        var upper = span.upperBound
        let bin = Frames(binFrames)
        // The spans come in order, so the walk from the end is short.
        var first = covered.count
        while first > 0, covered[first - 1].upperBound + bin > lower { first -= 1 }
        var last = first
        while last < covered.count, covered[last].lowerBound < upper + bin {
            lower = min(lower, covered[last].lowerBound)
            upper = max(upper, covered[last].upperBound)
            last += 1
        }
        covered.replaceSubrange(first..<last, with: [lower..<upper])
    }
}
