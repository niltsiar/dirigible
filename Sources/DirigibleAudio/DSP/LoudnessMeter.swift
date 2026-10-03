import AVFoundation
import DirigibleCore

/// A loudness in LUFS. A distinct type, so that a loudness and a dB gain do not mix.
public struct LUFS: Hashable, Comparable, Sendable {
    public let value: Double

    public static func < (a: LUFS, b: LUFS) -> Bool { a.value < b.value }
}

/// One direct-form-I biquad in Double, with the state in plain fields. `vDSP.Biquad` is not
/// Sendable, so a Sendable meter cannot hold it (run 8a, L2).
struct Biquad: Sendable {
    let b0, b1, b2, a1, a2: Double
    var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

    init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        (self.b0, self.b1, self.b2, self.a1, self.a2) = (b0, b1, b2, a1, a2)
    }

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        (x2, x1, y2, y1) = (x1, x, y1, y)
        return y
    }

    /// Sets each state value under 1e-30 to 0. Exact zeros after a signal otherwise keep the state
    /// subnormal, which made the meter 47 times slower on the Intel Mac. `feed` calls it once per
    /// chunk: a guard in `process` costs 26% on every sample. The high-pass needs about 128 000
    /// samples to decay from 1e-30 to a subnormal value, and a chunk is at most 0.1 s.
    mutating func flush() {
        if abs(x1) < 1e-30 { x1 = 0 }
        if abs(x2) < 1e-30 { x2 = 0 }
        if abs(y1) < 1e-30 { y1 = 0 }
        if abs(y2) < 1e-30 { y2 = 0 }
    }
}

/// The channel-summed K-weighted mean square of each complete 400 ms block (75% overlap) of one
/// signal: 36 000 values for 1 h. A signal with a non-finite sample has no blocks.
public struct Loudness: Hashable, Sendable {
    static let absoluteGate = -70.0
    static let relativeGate = -10.0

    let blocks: [Double]

    /// The gated integrated loudness of ITU-R BS.1770-5. Nil when no block passes the two gates.
    /// The gates compare mean squares, not LUFS: `lufs` rises with the mean square, so the result
    /// is the same with no log10 per block. The live meter computes it at each step of a play
    /// (decision 0033).
    public var integrated: LUFS? {
        let absolute = Self.meanSquare(Self.absoluteGate)
        let (sum, count) = Self.sum(blocks, over: absolute)
        guard count > 0 else { return nil }
        let relative = max(absolute, sum / Double(count) * pow(10, Self.relativeGate / 10))
        let (gatedSum, gatedCount) = Self.sum(blocks, over: relative)
        guard gatedCount > 0 else { return nil }
        return LUFS(value: Self.lufs(gatedSum / Double(gatedCount)))
    }

    /// The sum and the count of the blocks over `threshold`.
    private static func sum(_ blocks: [Double], over threshold: Double) -> (sum: Double, count: Int) {
        var (sum, count) = (0.0, 0)
        for block in blocks where block > threshold {
            sum += block
            count += 1
        }
        return (sum, count)
    }

    /// The mean square of `lufs`: the inverse of `lufs(_:)`.
    static func meanSquare(_ lufs: Double) -> Double { pow(10, (lufs + 0.691) / 10) }

    /// The loudness of the signal after `gain`. It scales each block, so the gates act on the
    /// scaled blocks.
    public func withGain(_ gain: Gain) -> Loudness {
        let factor = pow(10, gain.dB / 10)
        return Loudness(blocks: blocks.map { $0 * factor })
    }

    /// The loudness of all blocks of `parts` as one signal. The gaps between the parts do not count.
    public init(union parts: [Loudness]) { blocks = parts.flatMap(\.blocks) }

    init(blocks: [Double]) { self.blocks = blocks }

    /// The loudness of a K-weighted mean square: -0.691 + 10 log10(meanSquare) (BS.1770-5, Annex 1).
    static func lufs(_ meanSquare: Double) -> Double { -0.691 + 10 * log10(meanSquare) }
}

/// A streaming ITU-R BS.1770-5 meter of one signal. It works in memory only and cannot throw.
public struct LoudnessMeter: Sendable {
    /// The frequency of the K-weighting shelf. The rate must put it under Nyquist.
    static let shelfFrequency = 1681.974450955533

    let sampleRate: Int
    /// 100 ms, rounded: a session can have any positive rate.
    let stepFrames: Int
    /// The shelf and the high-pass of each channel. The state continues across calls of `feed`.
    var filters: [(shelf: Biquad, highPass: Biquad)]
    var stepSum = 0.0
    var stepFilled = 0
    /// The sums of the last complete steps: at most the short-term window.
    var steps: [Double] = []
    var blocks: [Double] = []
    var nonFinite = false

    /// The steps of a 400 ms block, which is also the momentary window (EBU Tech 3341).
    static let blockSteps = 4
    /// The steps of the 3 s short-term window (EBU Tech 3341).
    static let shortTermSteps = 30

    /// Nil when the shelf frequency is at or over Nyquist (a rate of 3 363 Hz or less).
    public init?(sampleRate: Int, layout: ChannelLayout) {
        guard Double(sampleRate) / 2 > Self.shelfFrequency else { return nil }
        self.sampleRate = sampleRate
        stepFrames = Int((Double(sampleRate) / 10).rounded())
        filters = Array(repeating: Self.kWeighting(rate: Double(sampleRate)), count: layout.channelCount)
    }

    /// The two K-weighting stages for `rate`, from the analog prototype (BS.1770-5 Annex 1). At
    /// 48 kHz they give the table of the standard.
    static func kWeighting(rate: Double) -> (shelf: Biquad, highPass: Biquad) {
        let warp = Double.pi / rate
        var k = tan(warp * shelfFrequency)
        let q = 0.7071752369554196
        let vh = pow(10, 3.999843853973347 / 20)
        let vb = pow(vh, 0.4996667741545416)
        var a0 = 1 + k / q + k * k
        let shelf = Biquad(
            b0: (vh + vb * k / q + k * k) / a0, b1: 2 * (k * k - vh) / a0, b2: (vh - vb * k / q + k * k) / a0,
            a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
        k = tan(warp * 38.13547087602444)
        let highPassQ = 0.5003270373238773
        a0 = 1 + k / highPassQ + k * k
        let highPass = Biquad(
            b0: 1, b1: -2, b2: 1, a1: 2 * (k * k - 1) / a0, a2: (1 - k / highPassQ + k * k) / a0)
        return (shelf, highPass)
    }

    /// Adds the frames of `buffer`. Any block size works. The channel weights are 1 for mono and
    /// stereo, so the step sum adds the channels with no weight.
    /// Precondition: deinterleaved Float32 at the meter rate, with the channel count of the layout.
    public mutating func feed(_ buffer: AVAudioPCMBuffer) {
        let format = buffer.format
        precondition(
            format.commonFormat == .pcmFormatFloat32 && !format.isInterleaved
                && Int(format.channelCount) == filters.count && format.sampleRate == Double(sampleRate),
            "the loudness meter takes deinterleaved Float32 at its rate and channel count")
        guard let data = buffer.floatChannelData else { return }
        add(frames: Int(buffer.frameLength), stride: 1) { channel, start in UnsafePointer(data[channel] + start) }
    }

    /// Adds interleaved Float32 frames at the meter rate, with the channel count of the layout:
    /// the record path. It shares the inner loop of `feed(_ buffer:)`.
    mutating func feed(interleaved samples: UnsafeBufferPointer<Float>) {
        guard let base = samples.baseAddress else { return }
        let channels = filters.count
        add(frames: samples.count / channels, stride: channels) { channel, start in base + start * channels + channel }
    }

    /// The one inner loop of both feeds. `first(channel, frame)` points to the sample of that
    /// channel at that frame; the next frame is `stride` samples after it.
    private mutating func add(
        frames: Int, stride: Int, _ first: (_ channel: Int, _ frame: Int) -> UnsafePointer<Float>
    ) {
        var start = 0
        while start < frames {
            let count = min(frames - start, stepFrames - stepFilled)
            for channel in filters.indices {
                var (shelf, highPass) = filters[channel]
                let samples = first(channel, start)
                var sum = 0.0
                for index in 0..<count {
                    let y = highPass.process(shelf.process(Double(samples[index * stride])))
                    sum += y * y
                }
                shelf.flush()
                highPass.flush()
                filters[channel] = (shelf, highPass)
                // A NaN or an infinity gives a sum that is not finite, also in a step that never
                // completes. `result()` then has no blocks, so the integrated value of the live
                // meter stays nil until the next reset. M and S count the part as silence, and
                // the filters of the channel start again.
                if !sum.isFinite {
                    nonFinite = true
                    filters[channel] = Self.kWeighting(rate: Double(sampleRate))
                    sum = 0
                }
                stepSum += sum
            }
            start += count
            stepFilled += count
            if stepFilled == stepFrames {
                steps.append(stepSum)
                if steps.count > Self.shortTermSteps { steps.removeFirst() }
                if steps.count >= Self.blockSteps {
                    blocks.append(steps.suffix(Self.blockSteps).reduce(0, +) / Double(Self.blockSteps * stepFrames))
                }
                (stepSum, stepFilled) = (0, 0)
            }
        }
    }

    /// The loudness of the last 400 ms. Nil until 400 ms of steps complete, and for silence.
    public var momentary: LUFS? { window(Self.blockSteps) }

    /// The loudness of the last 3 s. Nil until 3 s of steps complete, and for silence.
    public var shortTerm: LUFS? { window(Self.shortTermSteps) }

    private func window(_ count: Int) -> LUFS? {
        guard steps.count >= count else { return nil }
        let meanSquare = steps.suffix(count).reduce(0, +) / Double(count * stepFrames)
        return meanSquare > 0 ? LUFS(value: Loudness.lufs(meanSquare)) : nil
    }

    /// The complete blocks so far. An incomplete block at the end does not count (EBU Tech 3341).
    public func result() -> Loudness { Loudness(blocks: nonFinite ? [] : blocks) }
}
