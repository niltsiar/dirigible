import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Sends `channels` through a new limiter at -1 dBTP in chunks of `chunk` frames, then drains
/// it, and gives the output channels.
func limited(_ channels: [[Float]], chunk: Int = 48_000, rate: Int = 48_000) throws -> [[Float]] {
    let layout = try #require(ChannelLayout(channelCount: channels.count))
    var limiter = TruePeakLimiter(ceiling: -1, rate: rate, layout: layout)
    let format = try #require(
        AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: AVAudioChannelCount(channels.count)))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk)))
    var output = [[Float]](repeating: [], count: channels.count)
    func collect() {
        for (index, samples) in DirigibleAudioTests.channels(buffer).enumerated() { output[index] += samples }
    }
    var start = 0
    while start < channels[0].count {
        let count = min(chunk, channels[0].count - start)
        for (index, samples) in channels.enumerated() {
            samples.withUnsafeBufferPointer {
                buffer.floatChannelData![index].update(from: $0.baseAddress! + start, count: count)
            }
        }
        buffer.frameLength = AVAudioFrameCount(count)
        limiter.process(buffer)
        collect()
        start += count
    }
    while limiter.drain(into: buffer) { collect() }
    return output
}

/// A 1 kHz sine at -20 dBFS peak with a 1 ms burst of an fs/4 sine at 1.0 FFS, 45 degrees, at
/// 1 s (analysis.md criterion 8, at a smaller size). The burst reads about +1 dBTP.
func burstSignal(seconds: Double = 3, rate: Int = 48_000) -> [Float] {
    let frames = Int(seconds * Double(rate))
    return (0..<frames).map { index -> Float in
        var value = 0.1 * sin(2 * .pi * 1000 * Double(index) / Double(rate))
        if (rate..<rate + rate / 1000).contains(index) { value += sin(.pi / 2 * Double(index) + .pi / 4) }
        return Float(value)
    }
}

/// Run 9a slice 2: the look-ahead true-peak limiter (design.md). The internal ceiling is
/// -1.05 dBTP, so an output reads at most -1.0 dBTP.
struct LimiterTests {
    /// A 1 kHz sine at +6 dBFS in the left channel and -20 dBFS in the right: one gain for both.
    @Test func aPeakOverTheCeilingComesOutAtTheCeiling() throws {
        let loud = tone([(1, 6)])[0]
        let quiet = tone([(1, -20)])[0]

        let out = try limited([loud, quiet])

        expectDBTP(try truePeak(out), -1.05, above: 0.05, below: 0.05, "the limited sine")
        let tail = 24_000..<48_000
        let ratio = Double(out[1][tail].map(abs).max()!) / Double(quiet[tail].map(abs).max()!)
        #expect(abs(20 * log10(ratio) - -7.05) < 0.05, "the right channel: \(20 * log10(ratio)) dB, not -7.05")
    }

    /// The 12 signals of candidate A: a sine near Nyquist up to +8 dBFS with clicks of +12 to
    /// +26 dB, 5 to 260 frames apart. Each reads at most 0.000002 dB over the internal ceiling.
    /// A hold of the ramp only (no FIR span) reads 0.003 to 0.014 dB over it, so the bound is
    /// 0.0001 dB, not the 0.05 dB margin.
    @Test func adversarialSignalsStayUnderTheCeiling() throws {
        var generator = SeededGenerator(seed: 7)
        for trial in 0..<12 {
            let signal = adversarial(&generator)
            let out = try limited([signal])
            expectDBTP(try truePeak([out[0]]), -1.05, above: 0.0001, below: 2, "trial \(trial)")
        }
    }

    /// The FIR history, the hold, the release, the mean, and the delay continue across chunks.
    @Test func theOutputDoesNotDependOnTheChunk() throws {
        var generator = SeededGenerator(seed: 11)
        let signal = adversarial(&generator) + burstSignal(seconds: 1.2)

        let small = try limited([signal], chunk: 480)
        let large = try limited([signal], chunk: 48_000)

        #expect(small[0].count == signal.count && large[0].count == signal.count, "the lengths")
        #expect(maxError(small[0], large[0]) <= 0x1p-20, "chunk 480 against 48 000: \(maxError(small[0], large[0]))")
    }

    /// Under the ceiling the gain is exactly 1, and the output has the input frames at the same
    /// places: the drain gives back the look-ahead delay.
    @Test func aSignalUnderTheCeilingPassesDelayedByTheLookAhead() throws {
        let signal = tone([(1, -1.5)])
        let rate = 48_000
        var limiter = TruePeakLimiter(ceiling: -1, rate: rate, layout: .stereo)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        for index in 0..<2 { buffer.floatChannelData![index].update(from: signal[index], count: 48_000) }

        limiter.process(buffer)

        #expect(Int(buffer.frameLength) == 48_000 - limiter.latency, "the first chunk keeps the look-ahead")
        #expect(limiter.latency == 250, "the latency at 48 kHz: \(limiter.latency)")
        let out = try limited(signal)
        #expect(out == signal, "the output differs from the input")
    }

    /// 300 ms to 500 ms after the burst, the 1 kHz part is back within 0.1 dB (a release of
    /// 50 ms leaves 0.006 dB), and 1.5 s after it each sample equals the input.
    @Test func theGainComesBack() throws {
        let signal = burstSignal()
        let out = try limited([signal])[0]

        expectDBTP(try truePeak([out]), -1.05, above: 0.05, below: 0.5, "the burst")
        let end = 48_048
        let window = end + 14_400..<end + 24_000
        let loss = ExportTests.rmsDB(Array(out[window])) - ExportTests.rmsDB(Array(signal[window]))
        #expect(abs(loss) <= 0.1, "the gain 300 ms after the burst: \(loss) dB")
        #expect(Array(out[end + 72_000..<signal.count]) == Array(signal[end + 72_000..<signal.count]), "the tail")
    }
}

/// One signal of the candidate A probe `lim3.py`: 12 000 frames at 48 kHz.
private func adversarial(_ generator: inout SeededGenerator) -> [Float] {
    let frequency = [11_000.0, 11_900, 12_000, 8_000, 15_000, 23_000].randomElement(using: &generator)!
    let phase = Double.random(in: 0..<6.28, using: &generator)
    let amplitude = pow(10, Double.random(in: 0...8, using: &generator) / 20)
    let gap = Int.random(in: 5...260, using: &generator)
    let click = pow(10, Double.random(in: 12...26, using: &generator) / 20)
    var signal = (0..<12_000).map { amplitude * sin(2 * .pi * frequency * Double($0) / 48_000 + phase) }
    for place in stride(from: 600, to: 12_000 - gap, by: 700) {
        signal[place + gap] += click * (Bool.random(using: &generator) ? 1 : -1)
        if Bool.random(using: &generator) { signal[place - gap] += click * (Bool.random(using: &generator) ? 1 : -1) }
    }
    return signal.map { Float($0) }
}
