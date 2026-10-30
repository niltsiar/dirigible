import Foundation

@testable import DirigibleAudio

/// Feeds `input` (one array for each channel) to `stage` in blocks of the sizes in `blocks`, in a
/// cycle, then calls `finish` and drops the first `latency` frames, so the output lines up with
/// the input.
func render<Stage: RenderStage>(_ stage: inout Stage, _ input: [[Float]], blocks: [Int] = [65_536]) -> [[Float]] {
    var output = input.map { _ in [Float]() }
    var (start, index) = (0, 0)
    while start < input[0].count {
        let count = min(blocks[index % blocks.count], input[0].count - start)
        for (channel, part) in stage.process(input.map { Array($0[start..<start + count]) }).enumerated() {
            output[channel] += part
        }
        (start, index) = (start + count, index + 1)
    }
    for (channel, part) in stage.finish().enumerated() { output[channel] += part }
    return output.map { Array($0.dropFirst(stage.latency)) }
}

/// The largest magnitude of `samples`.
func largest(_ samples: [Float]) -> Float { samples.map(abs).max() ?? 0 }

/// The ranges of the frames where `output` differs from `input`.
func changedRanges(_ input: [Float], _ output: [Float]) -> [Range<Int>] {
    var ranges: [Range<Int>] = []
    var start: Int?
    for index in 0...input.count {
        let changed = index < input.count && input[index] != output[index]
        if changed, start == nil { start = index }
        if !changed, let first = start {
            ranges.append(first..<index)
            start = nil
        }
    }
    return ranges
}

/// The vowel of the de-clip tests at 48 kHz: 12 harmonics of `f0` at 1/h^2 with phase h, with a
/// 3 Hz level swing of `swing` (0 for a steady vowel), scaled to a peak of 1 (U5g; `probe-s1` of
/// the run).
func swingVowel(_ f0: Double, swing: Double = 0.25, frames: Int = 48_000) -> [Double] {
    let raw = (0..<frames).map { frame in
        let time = Double(frame) / 48_000
        var sum = 0.0
        for harmonic in 1...12 {
            let h = Double(harmonic)
            sum += sin(2 * .pi * f0 * h * time + h) / (h * h)
        }
        return sum * (1 - swing + swing * sin(2 * .pi * 3 * time))
    }
    let peak = raw.map(abs).max() ?? 1
    return raw.map { $0 / peak }
}

/// `vowel` times `over` as float samples (the truth), and the same samples clipped at full scale.
func clipped(_ vowel: [Double], over: Double) -> (truth: [Float], clipped: [Float]) {
    let truth = vowel.map { Float($0 * over) }
    return (truth, truth.map { min(max($0, -1), 1) })
}

/// The error energy of `output` in the clipped samples of `clipped`, in dB over the error energy
/// of `clipped` there (C3): 0 dB for a fill that leaves the clip as it is.
func clipErrorDecibels(truth: [Float], clipped: [Float], output: [Float]) -> Double {
    var (base, error) = (0.0, 0.0)
    for index in clipped.indices where abs(clipped[index]) >= 1 {
        base += pow(Double(truth[index] - clipped[index]), 2)
        error += pow(Double(truth[index] - output[index]), 2)
    }
    return 10 * log10(error / base)
}

/// `samples` as integer PCM of `bits` with TPDF dither (one LSB, triangular), read back as
/// `AVAudioFile` reads it: the integer over 2^(bits - 1).
func dithered(_ samples: [Double], bits: Int, seed: UInt64) -> [Float] {
    var generator = SeededGenerator(seed: seed)
    let full = Double(1 << (bits - 1))
    var output: [Float] = []
    output.reserveCapacity(samples.count)
    for sample in samples {
        let first = Double(generator.next() >> 11) * 0x1p-53
        let second = Double(generator.next() >> 11) * 0x1p-53
        let level = (sample * full + first - second).rounded(.toNearestOrEven)
        output.append(Float(min(max(level, -full), full - 1) / full))
    }
    return output
}

/// One second of a sine at full peak whose crests sit `offset` of a sample after a frame (C2).
func steadyTone(_ hertz: Double, rate: Double, offset: Double) -> [Double] {
    let phase = Double.pi / 2 - 2 * .pi * hertz * (100 + offset) / rate
    return (0..<Int(rate)).map { sin(2 * .pi * hertz * Double($0) / rate + phase) }
}

/// The RBJ high-pass at `hertz`, Q 0.70711, in Double: the reference of the stage filters.
func highPassed(_ samples: [Double], hertz: Double, rate: Double = 48_000) -> [Double] {
    let omega = 2 * .pi * hertz / rate
    let (alpha, cosine) = (sin(omega) / (2 * 0.70711), cos(omega))
    let a0 = 1 + alpha
    let (b0, b1, a1, a2) = ((1 + cosine) / 2 / a0, -(1 + cosine) / a0, -2 * cosine / a0, (1 - alpha) / a0)
    var (x1, x2, y1, y2) = (0.0, 0.0, 0.0, 0.0)
    return samples.map { x in
        let y = b0 * x + b1 * x1 + b0 * x2 - a1 * y1 - a2 * y2
        (x2, x1, y2, y1) = (x1, x, y1, y)
        return y
    }
}

/// The vowel of the de-ess tests at 48 kHz: 44 harmonics of 180 Hz (to 7,920 Hz) at 1/h, times
/// 0.05, with a 10 ms fade-in. `start` is its first frame on the clock of the harmonics.
func sibilantVowel(frames: Int, start: Int) -> [Double] {
    (0..<frames).map { frame in
        let time = Double(start + frame) / 48_000
        var sum = 0.0
        for harmonic in 1...44 { sum += sin(2 * .pi * 180 * Double(harmonic) * time) / Double(harmonic) }
        return 0.05 * sum * (0.5 - 0.5 * cos(.pi * Double(min(frame, 480)) / 480))
    }
}

/// The "s" of the de-ess tests: 150 ms of white noise in -0.2...0.2 (seed 7), high-passed twice at
/// 5 kHz.
func sibilantBurst() -> [Double] {
    var generator = SeededGenerator(seed: 7)
    let noise = (0..<7_200).map { _ in -0.2 + 0.4 * Double(generator.next() >> 11) * 0x1p-53 }
    return highPassed(highPassed(noise, hertz: 5_000), hertz: 5_000)
}

/// A vowel of 500 ms, the "s" of 150 ms (frames 24,000 to 31,200), and the vowel again (C5).
func sibilantSpeech() -> [Float] {
    (sibilantVowel(frames: 24_000, start: 0) + sibilantBurst() + sibilantVowel(frames: 24_000, start: 31_200))
        .map { Float($0) }
}

/// The RBJ low-pass at `hertz`, Q 0.70711, in Double: the low half of the de-ess split.
func lowPassed(_ samples: [Double], hertz: Double, rate: Double = 48_000) -> [Double] {
    let omega = 2 * .pi * hertz / rate
    let (alpha, cosine) = (sin(omega) / (2 * 0.70711), cos(omega))
    let a0 = 1 + alpha
    let (b0, b1, a1, a2) = ((1 - cosine) / 2 / a0, (1 - cosine) / a0, -2 * cosine / a0, (1 - alpha) / a0)
    var (x1, x2, y1, y2) = (0.0, 0.0, 0.0, 0.0)
    return samples.map { x in
        let y = b0 * x + b1 * x1 + b0 * x2 - a1 * y1 - a2 * y2
        (x2, x1, y2, y1) = (x1, x, y1, y)
        return y
    }
}

/// The de-ess output with no cut at `hertz`: the sum of the two Linkwitz-Riley bands (each band two
/// RBJ filters), an allpass of `samples`.
func splitSum(_ samples: [Float], hertz: Double = 6_000) -> [Float] {
    let input = samples.map(Double.init)
    let low = lowPassed(lowPassed(input, hertz: hertz), hertz: hertz)
    let high = highPassed(highPassed(input, hertz: hertz), hertz: hertz)
    return zip(low, high).map { Float($0 + $1) }
}

/// The level in dB of `output` over `input` at `hertz`, from one DFT bin over `frames` (a whole
/// number of cycles at 48 kHz for a whole `hertz` and 48,000 frames).
func binGain(_ input: [Float], _ output: [Float], hertz: Double, frames: Range<Int>) -> Double {
    func magnitude(_ samples: [Float]) -> Double {
        var (real, imaginary) = (0.0, 0.0)
        for frame in frames {
            let angle = 2 * .pi * hertz * Double(frame) / 48_000
            real += Double(samples[frame]) * cos(angle)
            imaginary += Double(samples[frame]) * sin(angle)
        }
        return (real * real + imaginary * imaginary).squareRoot()
    }
    return 20 * log10(magnitude(output) / magnitude(input))
}

/// The RMS of `output` over `input` in the frames `frames`, in dB.
func rmsGain(_ input: [Float], _ output: [Float], frames: Range<Int>) -> Double {
    func energy(_ samples: [Float]) -> Double { frames.reduce(0) { $0 + Double(samples[$1]) * Double(samples[$1]) } }
    return 10 * log10(energy(output) / energy(input))
}
