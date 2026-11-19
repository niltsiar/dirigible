import Accelerate

/// The score of the best lag of a waveform match (F74, **Match rule**).
public struct MatchScore: Hashable, Sendable {
    /// The normalized correlation at the peak lag: 1 for an exact copy at any gain.
    public let peak: Float
    /// The peak over the largest absolute score more than 50 ms from the peak lag.
    public let ratio: Float

    public init(peak: Float, ratio: Float) { (self.peak, self.ratio) = (peak, ratio) }

    /// True when the peak is 0.2 or more and the ratio is 3 or more.
    public var isMatch: Bool { peak >= 0.2 && ratio >= 3 }
}

/// The result of `waveformMatch`.
enum WaveformMatch: Hashable, Sendable {
    /// `lag` is the reference frame of clip frame 0, `spread` the largest minus the smallest lag of
    /// the excerpts that match, or nil when fewer than 2 excerpts match: then the drift is not measured.
    case match(lag: Int, score: MatchScore, spread: Int?)
    case noMatch(best: MatchScore)
    /// No memory for the DFT setups of the coarse step.
    case noMemory
}

/// The make of a DFT setup, `vDSP_DFT_zrop_CreateSetup` but in a test, which gives nil for no memory.
typealias DFTSetupMake = (vDSP_DFT_Setup?, vDSP_Length, vDSP_DFT_Direction) -> vDSP_DFT_Setup?

/// The decimation factor of the coarse step: floor(rate / 2000), so 24 at 48 kHz and 22 at 44.1 kHz.
/// A coarse lag converts to frames by this factor, with no rounded rate.
func matchFactor(rate: Int) -> Int { max(1, rate / 2000) }

/// A low-pass FIR at 0.4 of the coarse rate (a Blackman windowed sinc of 8 x `factor` + 1 taps) and
/// a decimation by `factor`. It keeps the input that the next output needs, so the chunks of a stream
/// give the samples of one call on the whole signal. Output k starts at input frame k x `factor`.
struct Decimator {
    let factor: Int
    private let taps: [Float]
    private var pending: [Float] = []

    init(factor: Int) {
        self.factor = factor
        let half = 4 * factor
        let cutoff = 0.4 / Double(factor)
        taps = (-half...half).map { index in
            let x = Double(index)
            let sinc = index == 0 ? 2 * cutoff : sin(2 * .pi * cutoff * x) / (.pi * x)
            let phase = .pi * Double(index + half) / Double(half)
            return Float(sinc * (0.42 - 0.5 * cos(phase) + 0.08 * cos(2 * phase)))
        }
    }

    mutating func feed(_ chunk: UnsafeBufferPointer<Float>) -> [Float] {
        pending.append(contentsOf: chunk)
        guard pending.count >= taps.count else { return [] }
        let count = (pending.count - taps.count) / factor + 1
        var out = [Float](repeating: 0, count: count)
        vDSP_desamp(pending, vDSP_Stride(factor), taps, &out, vDSP_Length(count), vDSP_Length(taps.count))
        pending.removeFirst(count * factor)
        return out
    }
}

/// The normalized score of excerpts of one length at each position of one reference where the excerpt
/// fully overlaps it. The reference FFT is computed once, and the work holds four buffers of n floats
/// in place, n the power of 2 at or over the reference plus the excerpt length.
final class CoarseScores {
    /// The full-overlap positions: the reference length minus the excerpt length, plus 1.
    let positions: Int
    private let excerptLength: Int
    private let separation: Int
    private let length: Int
    /// DFT setups, not an `FFTSetup`: at 2^24 points the FFT setup holds 579 MiB, the DFT setups 100 MiB.
    private let forwardSetup: vDSP_DFT_Setup
    private let inverseSetup: vDSP_DFT_Setup
    private var spectrumReal: [Float]
    private var spectrumImaginary: [Float]
    private var workReal: [Float]
    private var workImaginary: [Float]
    /// The reference energy under the excerpt at each position.
    private var energies: [Float]
    private var values: [Float]

    /// `separation`: the positions of 50 ms at the coarse rate, which the ratio leaves out around the peak.
    /// Nil when `makeSetup` gives no setup: no memory.
    init?(
        reference: [Float], excerptLength: Int, separation: Int, makeSetup: DFTSetupMake = vDSP_DFT_zrop_CreateSetup
    ) {
        let length = 1 << max(1, Int.bitWidth - (reference.count + excerptLength - 1).leadingZeroBitCount)
        guard let forwardSetup = makeSetup(nil, vDSP_Length(length), .FORWARD) else { return nil }
        guard let inverseSetup = makeSetup(forwardSetup, vDSP_Length(length), .INVERSE) else {
            vDSP_DFT_DestroySetup(forwardSetup)
            return nil
        }
        (self.forwardSetup, self.inverseSetup, self.length) = (forwardSetup, inverseSetup, length)
        (self.excerptLength, self.separation) = (excerptLength, separation)
        positions = max(0, reference.count - excerptLength + 1)
        (spectrumReal, spectrumImaginary) = (
            [Float](repeating: 0, count: length / 2), [Float](repeating: 0, count: length / 2)
        )
        (workReal, workImaginary) = ([Float](repeating: 0, count: length / 2), [Float](repeating: 0, count: length / 2))
        energies = [Float](repeating: 0, count: length)
        values = [Float](repeating: 0, count: length)
        values.replaceSubrange(0..<reference.count, with: reference)
        forward(&spectrumReal, &spectrumImaginary)
        // A sliding sum in Double: a Float sum loses a quiet passage after a loud one.
        var energy = reference.prefix(excerptLength).reduce(0.0) { $0 + Double($1) * Double($1) }
        for position in 0..<positions {
            energies[position] = Float(energy)
            if position + excerptLength < reference.count {
                let (added, removed) = (Double(reference[position + excerptLength]), Double(reference[position]))
                energy = max(0, energy + added * added - removed * removed)
            }
        }
    }

    deinit {
        vDSP_DFT_DestroySetup(inverseSetup)
        vDSP_DFT_DestroySetup(forwardSetup)
    }

    /// The scores of the last `match`, one for each position.
    var scores: ArraySlice<Float> { values[0..<positions] }

    /// The position of the largest score of `excerpt` and its score. A position whose reference
    /// energy is under 1e-4 of the excerpt energy scores 0, so silence never wins.
    func match(_ excerpt: [Float]) -> (position: Int, score: MatchScore) {
        let excerptEnergy = excerpt.reduce(0.0) { $0 + Double($1) * Double($1) }
        values.withUnsafeMutableBufferPointer { values in
            values.update(repeating: 0)
            _ = values.update(fromContentsOf: excerpt)
        }
        forward(&workReal, &workImaginary)
        let (zero, nyquist) = (workReal[0] * spectrumReal[0], workImaginary[0] * spectrumImaginary[0])
        withSplit(&workReal, &workImaginary) { work in
            withSplit(&spectrumReal, &spectrumImaginary) { spectrum in
                withUnsafeMutablePointer(to: &work) { work in
                    vDSP_zvmul(work, 1, &spectrum, 1, work, 1, vDSP_Length(length / 2), -1)
                }
            }
        }
        (workReal[0], workImaginary[0]) = (zero, nyquist)
        withSplit(&workReal, &workImaginary) { work in
            vDSP_DFT_Execute(inverseSetup, work.realp, work.imagp, work.realp, work.imagp)
            values.withUnsafeMutableBufferPointer { values in
                values.withMemoryRebound(to: DSPComplex.self) {
                    vDSP_ztoc(&work, 1, $0.baseAddress!, 2, vDSP_Length(length / 2))
                }
            }
        }
        // Two forward real FFTs scale by 2 each, and the inverse does not divide by n: 4n in all.
        let scale = 1 / (4 * Double(length))
        var (peak, best) = (-Float.infinity, 0)
        for position in 0..<positions {
            let energy = Double(energies[position])
            let score =
                energy < 1e-4 * excerptEnergy
                ? 0 : Float(Double(values[position]) * scale / (excerptEnergy * energy).squareRoot())
            values[position] = score
            if score > peak { (peak, best) = (score, position) }
        }
        guard positions > 0 else { return (0, MatchScore(peak: 0, ratio: 0)) }
        var second: Float = 0
        for position in 0..<positions where abs(position - best) > separation {
            second = max(second, abs(values[position]))
        }
        return (best, MatchScore(peak: peak, ratio: second > 0 ? peak / second : .infinity))
    }

    /// The packed real FFT of `values` into `real` and `imaginary`.
    private func forward(_ real: inout [Float], _ imaginary: inout [Float]) {
        withSplit(&real, &imaginary) { split in
            values.withUnsafeBufferPointer { values in
                values.withMemoryRebound(to: DSPComplex.self) {
                    vDSP_ctoz($0.baseAddress!, 2, &split, 1, vDSP_Length(length / 2))
                }
            }
            vDSP_DFT_Execute(forwardSetup, split.realp, split.imagp, split.realp, split.imagp)
        }
    }
}

private func withSplit<Result>(
    _ real: inout [Float], _ imaginary: inout [Float], _ body: (inout DSPSplitComplex) -> Result
) -> Result {
    real.withUnsafeMutableBufferPointer { real in
        imaginary.withUnsafeMutableBufferPointer { imaginary in
            var split = DSPSplitComplex(realp: real.baseAddress!, imagp: imaginary.baseAddress!)
            return body(&split)
        }
    }
}

/// The best full-overlap position of `excerpt` in `window`, both at the session rate: the largest
/// normalized correlation, with the window energy as a sliding sum in Double.
func fineShift(_ excerpt: [Float], in window: [Float]) -> Int {
    let count = window.count - excerpt.count + 1
    guard count > 1 else { return 0 }
    let excerptEnergy = excerpt.reduce(0.0) { $0 + Double($1) * Double($1) }
    var energy = window.prefix(excerpt.count).reduce(0.0) { $0 + Double($1) * Double($1) }
    var (peak, best) = (-Double.infinity, 0)
    window.withUnsafeBufferPointer { window in
        for shift in 0..<count {
            var dot: Float = 0
            vDSP_dotpr(excerpt, 1, window.baseAddress! + shift, 1, &dot, vDSP_Length(excerpt.count))
            let score = energy < 1e-4 * excerptEnergy ? 0 : Double(dot) / (excerptEnergy * energy).squareRoot()
            if score > peak { (peak, best) = (score, shift) }
            if shift + 1 < count {
                let (added, removed) = (Double(window[shift + excerpt.count]), Double(window[shift]))
                energy = max(0, energy + added * added - removed * removed)
            }
        }
    }
    return best
}

/// The clip ranges of the excerpts (F74, **Excerpts**): one range of the whole clip under 60 s;
/// else 20 s in each third of the clip, at the 20 s of that third with the largest sum of the window
/// mean squares. Window w of `windowMeanSquares` starts at clip frame w x `window`.
func excerptRanges(clipLength: Int, windowMeanSquares: [Float], window: Int, rate: Int) -> [Range<Int>] {
    let length = 20 * rate
    guard clipLength >= 3 * length else { return [0..<clipLength] }
    let span = length / window
    return (0..<3).map { third in
        let (low, high) = (third * clipLength / 3, (third + 1) * clipLength / 3)
        let first = (low + window - 1) / window
        let last = (high - length) / window
        guard first <= last, last + span <= windowMeanSquares.count else { return high - length..<high }
        var sum = windowMeanSquares[first..<first + span].reduce(0.0) { $0 + Double($1) }
        var (best, start) = (sum, first)
        for index in first..<last {
            sum += Double(windowMeanSquares[index + span]) - Double(windowMeanSquares[index])
            if sum > best { (best, start) = (sum, index + 1) }
        }
        return start * window..<start * window + length
    }
}

/// Matches a clip against a reference span (F74, **Match**). `clipFrames` and `referenceFrames` read
/// the mono frames of a range at the session rate: clip frames from the clip start, and reference
/// frames from the span start. `reference2k` is the span through `Decimator(factor: matchFactor(rate:))`,
/// and `windowMeanSquares` the 50 ms window levels of the clip. Each excerpt finds its coarse position
/// in one shared reference FFT; the excerpts that pass the match rule refine it at the session rate in
/// a window of 2 coarse frames on each side. The lag is the lower median of their lags.
func waveformMatch<Failure: Error>(
    clipLength: Int, windowMeanSquares: [Float], rate: Int, reference2k: [Float], referenceLength: Int,
    clipFrames: (Range<Int>) throws(Failure) -> [Float], referenceFrames: (Range<Int>) throws(Failure) -> [Float],
    makeSetup: DFTSetupMake = vDSP_DFT_zrop_CreateSetup
) throws(Failure) -> WaveformMatch {
    let factor = matchFactor(rate: rate)
    let window = max(1, rate / 20)
    let ranges = excerptRanges(clipLength: clipLength, windowMeanSquares: windowMeanSquares, window: window, rate: rate)
    var excerpts: [[Float]] = []
    for range in ranges {
        var decimator = Decimator(factor: factor)
        excerpts.append(try clipFrames(range).withUnsafeBufferPointer { decimator.feed($0) })
    }
    guard !excerpts[0].isEmpty else { return .noMatch(best: MatchScore(peak: 0, ratio: 0)) }
    let separation = Int((Double(rate) / Double(factor) / 20).rounded())
    guard
        let coarse = CoarseScores(
            reference: reference2k, excerptLength: excerpts[0].count, separation: separation, makeSetup: makeSetup)
    else { return .noMemory }
    var (matches, best): ([(lag: Int, score: MatchScore)], MatchScore?) = ([], nil)
    for (range, excerpt) in zip(ranges, excerpts) {
        let (position, score) = coarse.match(excerpt)
        if best.map({ score.peak > $0.peak }) ?? true { best = score }
        guard score.isMatch else { continue }
        let start = position * factor
        let low = max(0, start - 2 * factor)
        let high = min(referenceLength, start + range.count + 2 * factor)
        let shift = fineShift(try clipFrames(range), in: try referenceFrames(low..<high))
        matches.append((low + shift - range.lowerBound, score))
    }
    guard !matches.isEmpty else { return .noMatch(best: best ?? MatchScore(peak: 0, ratio: 0)) }
    let sorted = matches.sorted { $0.lag < $1.lag }
    let median = sorted[(sorted.count - 1) / 2]
    let spread = sorted.count < 2 ? nil : sorted[sorted.count - 1].lag - sorted[0].lag
    return .match(lag: median.lag, score: median.score, spread: spread)
}
