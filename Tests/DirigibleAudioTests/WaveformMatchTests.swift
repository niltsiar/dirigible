import Accelerate
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// A seeded speech-like signal, as probe P1 of F74: noise bursts of 0.1 to 0.6 s at 0.05 to 0.3
/// of full scale, with gaps of 0.05 to 0.8 s at 0.002. A frame is a function of the seed and its
/// index, so a test reads any range without the whole signal in memory.
struct SpeechLike {
    let seed: UInt64
    let length: Int
    private let starts: [Int]
    private let levels: [Float]

    init(seconds: Double, rate: Int, seed: UInt64) {
        var random = SeededGenerator(seed: seed)
        var (starts, levels, frame) = ([Int](), [Float](), 0)
        let length = Int(seconds * Double(rate))
        while frame < length {
            starts.append(frame)
            levels.append(Float.random(in: 0.05...0.3, using: &random))
            frame += Int(Double.random(in: 0.1...0.6, using: &random) * Double(rate))
            starts.append(frame)
            levels.append(0.002)
            frame += Int(Double.random(in: 0.05...0.8, using: &random) * Double(rate))
        }
        (self.seed, self.length, self.starts, self.levels) = (seed, length, starts, levels)
    }

    /// The frames of `range`; a frame outside the signal is 0.
    func frames(_ range: Range<Int>) -> [Float] {
        var out = [Float](repeating: 0, count: range.count)
        var part = max(0, (starts.lastIndex { $0 <= max(range.lowerBound, 0) } ?? 0))
        for frame in range where frame >= 0 && frame < length {
            while part + 1 < starts.count && starts[part + 1] <= frame { part += 1 }
            out[frame - range.lowerBound] = levels[part] * Self.noise(seed, frame)
        }
        return out
    }

    /// A uniform value in -1..<1 from the seed and the frame (SplitMix64 of both).
    static func noise(_ seed: UInt64, _ frame: Int) -> Float {
        var value = seed &* 0xD1B5_4A32_D192_ED03 &+ UInt64(frame) &* 0x9E37_79B9_7F4A_7C15
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return Float(Int64(bitPattern: value ^ (value >> 31)) >> 40) / Float(1 << 23)
    }
}

/// A zero-phase low-pass FIR at `cutoff` Hz (a Blackman windowed sinc of 129 taps) over `signal`.
func lowPass(_ signal: [Float], cutoff: Double, rate: Int) -> [Float] {
    let half = 64
    let taps = (-half...half).map { index -> Float in
        let x = Double(index)
        let sinc = index == 0 ? 2 * cutoff / Double(rate) : sin(2 * .pi * cutoff / Double(rate) * x) / (.pi * x)
        let phase = 2 * .pi * Double(index + half) / Double(2 * half)
        return Float(sinc * (0.42 - 0.5 * cos(phase) + 0.08 * cos(2 * phase)))
    }
    let padded = [Float](repeating: 0, count: half) + signal + [Float](repeating: 0, count: half)
    var out = [Float](repeating: 0, count: signal.count)
    vDSP_conv(padded, 1, taps, 1, &out, 1, vDSP_Length(signal.count), vDSP_Length(taps.count))
    return out
}

/// The C2 copy of `clip`: low-passed at 3.4 kHz, times 0.3.
func degraded(_ clip: [Float], rate: Int) -> [Float] {
    lowPass(clip, cutoff: 3400, rate: rate).map { 0.3 * $0 }
}

/// Adds uniform noise at -40 dBFS RMS to `signal`.
func addNoise(_ signal: inout [Float], seed: UInt64) {
    let amplitude = Float(0.01 * 3.0.squareRoot())
    for index in signal.indices { signal[index] += amplitude * SpeechLike.noise(seed, index) }
}

/// `waveformMatch` on readers of a clip and a reference, as the shared read feeds it: the 50 ms
/// window mean squares of the clip, and the reference through a `Decimator` in chunks of an odd size.
func match(
    clipLength: Int, referenceLength: Int, rate: Int,
    clip: (Range<Int>) -> [Float], reference: (Range<Int>) -> [Float]
) -> WaveformMatch {
    let window = LevelSeries.window(rate: rate).count
    var squares: [Float] = []
    for start in stride(from: 0, to: clipLength, by: window * 200) {
        let frames = clip(start..<min(start + window * 200, clipLength))
        for first in stride(from: 0, to: frames.count, by: window) {
            let part = frames[first..<min(first + window, frames.count)]
            squares.append(part.reduce(0) { $0 + $1 * $1 } / Float(part.count))
        }
    }
    var decimator = Decimator(factor: matchFactor(rate: rate))
    var reference2k: [Float] = []
    for start in stride(from: 0, to: referenceLength, by: 65_537) {
        let frames = reference(start..<min(start + 65_537, referenceLength))
        reference2k += frames.withUnsafeBufferPointer { decimator.feed($0) }
    }
    return waveformMatch(
        clipLength: clipLength, windowMeanSquares: squares, rate: rate, reference2k: reference2k,
        referenceLength: referenceLength, clipFrames: clip, referenceFrames: reference)
}

/// `match` on two arrays.
func match(_ clip: [Float], in reference: [Float], rate: Int) -> WaveformMatch {
    match(
        clipLength: clip.count, referenceLength: reference.count, rate: rate, clip: { Array(clip[$0]) },
        reference: { Array(reference[$0]) })
}

/// The C1 reference: another speech-like signal of `seconds`, with `copy` from frame `lag`.
func reference(seconds: Double, rate: Int, holding copy: [Float], at lag: Int) -> [Float] {
    var reference = SpeechLike(seconds: seconds, rate: rate, seed: 2).frames(0..<Int(seconds * Double(rate)))
    reference.replaceSubrange(lag..<lag + copy.count, with: copy)
    return reference
}

struct WaveformMatchTests {
    let rate = 48_000
    let clip = SpeechLike(seconds: 90, rate: 48_000, seed: 1).frames(0..<90 * 48_000)

    @Test func anExactCopyGivesItsLagAndAPeakOfOne() {
        let result = match(
            clip, in: reference(seconds: 150, rate: rate, holding: clip.map { 0.5 * $0 }, at: 1_788_000), rate: rate)
        guard case .match(let lag, let score, let spread) = result else { return #expect(Bool(false), "\(result)") }
        #expect(lag == 1_788_000)
        #expect((0.99...1.01).contains(score.peak), "\(score)")
        #expect(spread == 0)
    }

    @Test(arguments: [(1_788_000, 48), (1_788_007, 2)])
    func aDegradedCopyIsWithinOneMillisecond(lag: Int, tolerance: Int) {
        var reference = reference(seconds: 150, rate: rate, holding: degraded(clip, rate: rate), at: lag)
        addNoise(&reference, seed: 5)
        let result = match(clip, in: reference, rate: rate)
        guard case .match(let found, _, _) = result else { return #expect(Bool(false), "\(result)") }
        #expect(abs(found - lag) <= tolerance, "lag \(found), true lag \(lag)")
    }

    @Test func anUnrelatedSignalIsNoMatch() {
        let reference = SpeechLike(seconds: 150, rate: rate, seed: 3).frames(0..<150 * rate)
        let result = match(clip, in: reference, rate: rate)
        guard case .noMatch(let best) = result else { return #expect(Bool(false), "\(result)") }
        #expect(best.peak < 0.2 || best.ratio < 3, "\(best)")
    }

    @Test func theMatchRuleHasTwoThresholds() {
        #expect(MatchScore(peak: 0.21, ratio: 3.1).isMatch)
        #expect(!MatchScore(peak: 0.19, ratio: 3.1).isMatch)
        #expect(!MatchScore(peak: 0.21, ratio: 2.9).isMatch)
        #expect(MatchScore(peak: 0.987, ratio: 40.8).isMatch)
        #expect(!MatchScore(peak: 0.018, ratio: 1.08).isMatch)
    }

    /// C8: a 20 min clip; the reference holds it from 30 s on, stretched by `ratio`. 100 ppm moves
    /// the first and the last excerpt centers at least 420 s apart, so at least 42 ms.
    @Test(arguments: [(1.0001, 1_920...5_760), (1.0, 0...0)])
    func aDriftingCopyReportsItsSpread(ratio: Double, spreads: ClosedRange<Int>) {
        let (length, lag) = (20 * 60 * rate, 30 * rate)
        let signal = SpeechLike(seconds: 20 * 60, rate: rate, seed: 7)
        let other = SpeechLike(seconds: 22 * 60, rate: rate, seed: 8)
        let referenceLength = lag + Int(Double(length) * ratio) + 30 * rate
        let result = match(
            clipLength: length, referenceLength: referenceLength, rate: rate, clip: { signal.frames($0) },
            reference: { range in
                let background = other.frames(range)
                let low = max(range.lowerBound, lag)
                let high = min(range.upperBound, lag + Int(Double(length - 1) * ratio))
                guard low < high else { return background }
                let first = Int(Double(low - lag) / ratio)
                let source = signal.frames(first..<Int(Double(high - lag) / ratio) + 2)
                var out = background
                for frame in low..<high {
                    let time = Double(frame - lag) / ratio - Double(first)
                    let index = Int(time)
                    let weight = Float(time - Double(index))
                    out[frame - range.lowerBound] = source[index] * (1 - weight) + source[index + 1] * weight
                }
                return out
            })
        guard case .match(let found, _, let spread) = result else { return #expect(Bool(false), "\(result)") }
        #expect(spread.map(spreads.contains) == true, "spread \(String(describing: spread)) frames")
        #expect(abs(found - lag) <= Int(Double(length) * (ratio - 1)) + 48, "lag \(found)")
    }

    /// C8: the reference holds only the first third of the clip, so 1 of the 3 excerpts matches.
    @Test func oneMatchedExcerptGivesNoSpread() {
        let firstThird = Array(clip[0..<30 * rate])
        let result = match(
            clip, in: reference(seconds: 150, rate: rate, holding: firstThird, at: 1_788_000), rate: rate)
        guard case .match(let lag, _, let spread) = result else { return #expect(Bool(false), "\(result)") }
        #expect(lag == 1_788_000)
        #expect(spread == nil, "spread \(String(describing: spread))")
    }

    @Test func aSessionAt44100FindsTheExactLag() {
        let rate = 44_100
        #expect(matchFactor(rate: rate) == 22)
        let clip = SpeechLike(seconds: 90, rate: rate, seed: 1).frames(0..<90 * rate)
        let lag = 1_642_725
        let result = match(clip, in: reference(seconds: 150, rate: rate, holding: clip, at: lag), rate: rate)
        guard case .match(let found, _, _) = result else { return #expect(Bool(false), "\(result)") }
        #expect(found == lag)
    }

    @Test func aRandomLagIsFoundExactly() {
        var random = SeededGenerator(seed: 41)
        for _ in 0..<3 {
            let lag = Int.random(in: 0..<60 * rate, using: &random)
            let clip = SpeechLike(seconds: 40, rate: rate, seed: random.next()).frames(0..<40 * rate)
            let result = match(clip, in: reference(seconds: 110, rate: rate, holding: clip, at: lag), rate: rate)
            guard case .match(let found, _, _) = result else { return #expect(Bool(false), "lag \(lag): \(result)") }
            #expect(found == lag)
        }
    }

    @Test func theStreamedDecimationEqualsTheWholeDecimation() {
        let signal = SpeechLike(seconds: 3, rate: rate, seed: 9).frames(0..<3 * rate + 13)
        var whole = Decimator(factor: 24)
        let expected = signal.withUnsafeBufferPointer { whole.feed($0) }
        var streamed = Decimator(factor: 24)
        var out: [Float] = []
        var (start, sizes) = (0, [1, 7, 4_099, 513, 23, 40_001])
        while start < signal.count {
            let size = sizes.removeFirst()
            sizes.append(size)
            let end = min(start + size, signal.count)
            out += signal[start..<end].withUnsafeBufferPointer { streamed.feed($0) }
            start = end
        }
        #expect(abs(expected.count - signal.count / 24) <= 20, "\(expected.count) samples")
        #expect(out.count == expected.count)
        let same = zip(out, expected).allSatisfy { abs($0 - $1) <= 1e-6 }
        #expect(same, "the streamed samples differ")
    }

    @Test func aLoudUnrelatedBurstDoesNotWin() {
        var reference = reference(seconds: 240, rate: rate, holding: degraded(clip, rate: rate), at: 1_788_000)
        let burst = SpeechLike(seconds: 60, rate: rate, seed: 4).frames(0..<60 * rate).map { 10 * 0.3 * $0 }
        reference.replaceSubrange(157 * rate..<217 * rate, with: burst)
        let result = match(clip, in: reference, rate: rate)
        guard case .match(let found, let score, _) = result else { return #expect(Bool(false), "\(result)") }
        #expect(abs(found - 1_788_000) <= 48, "lag \(found)")
        #expect(score.isMatch)
    }

    /// C16b: zeros at the span edges, a 100 s run of zeros, and a passage at -80 dBFS.
    @Test func silenceInTheReferenceScoresZero() throws {
        var reference = reference(seconds: 340, rate: rate, holding: degraded(clip, rate: rate), at: 1_788_000)
        for range in [0..<30 * rate, 140 * rate..<240 * rate, 310 * rate..<340 * rate] {
            reference.replaceSubrange(range, with: repeatElement(0, count: range.count))
        }
        for frame in 240 * rate..<300 * rate { reference[frame] = 1.7e-4 * SpeechLike.noise(6, frame) }
        let result = match(clip, in: reference, rate: rate)
        guard case .match(let found, _, _) = result else { return #expect(Bool(false), "\(result)") }
        #expect(abs(found - 1_788_000) <= 48, "lag \(found)")

        var clipDecimator = Decimator(factor: 24)
        var referenceDecimator = Decimator(factor: 24)
        let excerpt = clip.withUnsafeBufferPointer { clipDecimator.feed($0) }
        let coarse = try #require(
            CoarseScores(
                reference: reference.withUnsafeBufferPointer { referenceDecimator.feed($0) },
                excerptLength: excerpt.count, separation: 100))
        _ = coarse.match(excerpt)
        let over = coarse.scores.filter { $0 > 1.00001 || !$0.isFinite }.count
        #expect(over == 0, "\(over) scores over 1")
        let zeroRun = coarse.scores.indices.contains(290_000) ? coarse.scores[290_000] : -1
        #expect(zeroRun == 0, "a lag in the zero run scores \(zeroRun)")
    }

    /// The floor is 1e-4 of the excerpt energy: a copy at 1e-3 of its energy, between zeros, is a
    /// candidate and matches.
    @Test func aQuietCopyOverTheFloorMatches() {
        var reference = [Float](repeating: 0, count: 150 * rate)
        reference.replaceSubrange(1_788_000..<1_788_000 + clip.count, with: clip.map { 0.0316 * $0 })
        let result = match(clip, in: reference, rate: rate)
        guard case .match(let found, _, _) = result else { return #expect(Bool(false), "\(result)") }
        #expect(found == 1_788_000)
    }
}
