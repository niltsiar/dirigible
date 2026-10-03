import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// A 1 kHz sine with the same phase in each channel. Each part has its length and its peak in
/// dBFS (-infinity gives silence). The phase continues across the parts.
func tone(_ parts: [(seconds: Double, dBFS: Double)], rate: Int = 48_000, layout: ChannelLayout = .stereo) -> [[Float]]
{
    var samples: [Float] = []
    for part in parts {
        let amplitude = pow(10, part.dBFS / 20)
        let start = samples.count
        let frames = Int((part.seconds * Double(rate)).rounded())
        samples += (start..<start + frames).map { Float(amplitude * sin(2 * .pi * 1000 * Double($0) / Double(rate))) }
    }
    return Array(repeating: samples, count: layout.channelCount)
}

/// Feeds the channels to a new meter in blocks of `block` frames and gives the result.
func measure(_ channels: [[Float]], rate: Int = 48_000, block: Int = 65_536) throws -> Loudness {
    let layout = try #require(ChannelLayout(channelCount: channels.count))
    var meter = try #require(LoudnessMeter(sampleRate: rate, layout: layout))
    let format = try #require(
        AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: AVAudioChannelCount(channels.count)))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(block)))
    var start = 0
    while start < channels[0].count {
        let count = min(block, channels[0].count - start)
        for (index, samples) in channels.enumerated() {
            samples.withUnsafeBufferPointer {
                buffer.floatChannelData![index].update(from: $0.baseAddress! + start, count: count)
            }
        }
        buffer.frameLength = AVAudioFrameCount(count)
        meter.feed(buffer)
        start += count
    }
    return meter.result()
}

/// Records an issue that starts with `label` when `value` is nil or not within `tolerance`.
func expectLUFS(
    _ value: LUFS?, _ expected: Double, tolerance: Double = 0.1, _ label: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let near = value.map { abs($0.value - expected) <= tolerance } ?? false
    #expect(
        near, "\(label): read \(value.map { "\($0.value)" } ?? "nil"), not \(expected)", sourceLocation: sourceLocation)
}

/// Run 8a criteria 1 to 10, 14, and 15: ITU-R BS.1770-5 with the EBU Tech 3341 (2023) signals of
/// Table 1 (cases 1 to 5), all at 48 kHz unless named.
struct LoudnessTests {
    @Test func case1StereoSine() throws {
        expectLUFS(try measure(tone([(20, -23)])).integrated, -23, "case 1")
    }

    @Test func case2StereoSine() throws {
        expectLUFS(try measure(tone([(20, -33)])).integrated, -33, "case 2")
    }

    /// With no relative gate, case 3 reads about -24.2.
    @Test func case3RelativeGate() throws {
        expectLUFS(try measure(tone([(10, -36), (60, -23), (10, -36)])).integrated, -23, "case 3")
    }

    @Test func case4BothGates() throws {
        let signal = tone([(10, -72), (10, -36), (60, -23), (10, -36), (10, -72)])
        expectLUFS(try measure(signal).integrated, -23, "case 4")
    }

    /// Case 4 cannot catch a missing absolute gate: the relative gate removes the -72 blocks too.
    @Test func absoluteGateRefusesQuietAudio() throws {
        let quiet = try measure(tone([(20, -75)])).integrated
        #expect(quiet == nil, "absolute gate -75: read \(quiet.map { "\($0.value)" } ?? "nil"), not nil")
        expectLUFS(try measure(tone([(20, -65)])).integrated, -65, "absolute gate -65")
    }

    /// The -20 part ends at 40.1 s, inside a block.
    @Test func case5BlockEdge() throws {
        expectLUFS(try measure(tone([(20, -26), (20.1, -20), (20, -26)])).integrated, -23, "case 5")
    }

    /// Decision 0008: the mono sine reads 3 LU under the same sine in both channels.
    @Test func monoSineReadsThreeLower() throws {
        expectLUFS(try measure(tone([(20, -23)], layout: .mono)).integrated, -26, "mono")
    }

    /// The gain in dB of one biquad at `frequency`.
    static func gain(_ filter: Biquad, at frequency: Double, rate: Double) -> Double {
        let w = 2 * Double.pi * frequency / rate
        let numerator = hypot(
            filter.b0 + filter.b1 * cos(w) + filter.b2 * cos(2 * w), filter.b1 * sin(w) + filter.b2 * sin(2 * w))
        let denominator = hypot(
            1 + filter.a1 * cos(w) + filter.a2 * cos(2 * w), filter.a1 * sin(w) + filter.a2 * sin(2 * w))
        return 20 * log10(numerator / denominator)
    }

    @Test func filterMatchesTheTableAndFollowsTheRate() throws {
        // BS.1770-5 Annex 1, Tables 1 and 2 (48 kHz).
        let shelf = Biquad(
            b0: 1.53512485958697, b1: -2.69169618940638, b2: 1.19839281085285, a1: -1.69065929318241,
            a2: 0.73248077421585)
        let highPass = Biquad(b0: 1, b1: -2, b2: 1, a1: -1.99004745483398, a2: 0.99007225036621)
        let (computedShelf, computedHighPass) = LoudnessMeter.kWeighting(rate: 48_000)
        for (computed, table, name) in [(computedShelf, shelf, "shelf"), (computedHighPass, highPass, "high-pass")] {
            let pairs = [
                (computed.b0, table.b0), (computed.b1, table.b1), (computed.b2, table.b2), (computed.a1, table.a1),
                (computed.a2, table.a2),
            ]
            #expect(pairs.allSatisfy { abs($0 - $1) <= 1e-6 }, "the 48 kHz \(name) table: \(pairs)")
        }

        for rate in [44_100.0, 96_000.0] {
            let (rateShelf, rateHighPass) = LoudnessMeter.kWeighting(rate: rate)
            for frequency in [40.0, 10_000.0] {
                let table =
                    Self.gain(shelf, at: frequency, rate: 48_000) + Self.gain(highPass, at: frequency, rate: 48_000)
                let computed =
                    Self.gain(rateShelf, at: frequency, rate: rate) + Self.gain(rateHighPass, at: frequency, rate: rate)
                #expect(
                    abs(computed - table) <= 0.05,
                    "the gain at \(frequency) Hz and \(rate) Hz: \(computed) dB, not \(table) dB")
            }
            expectLUFS(
                try measure(tone([(20, -23)], rate: Int(rate)), rate: Int(rate)).integrated, -23, "case 1 at \(rate)")
        }
    }

    /// Tech 3341: an incomplete gating block at the end is discarded.
    @Test func shortSilentOrNonFiniteAudioHasNoMeasurement() throws {
        let short = try measure(tone([(0.3, -23)])).integrated
        #expect(short == nil, "300 ms: read \(short.map { "\($0.value)" } ?? "nil"), not nil")
        expectLUFS(try measure(tone([(0.4, -23)])).integrated, -23, "400 ms")
        let silence = try measure(tone([(20, -.infinity)])).integrated
        #expect(silence == nil, "silence: read \(silence.map { "\($0.value)" } ?? "nil"), not nil")
        // The NaN comes after the complete block, so only the non-finite check gives nil.
        var poisoned = tone([(0.4, -23)])
        poisoned[0].append(.nan)
        poisoned[1].append(0)
        let nan = try measure(poisoned).integrated
        #expect(nan == nil, "a NaN sample: read \(nan.map { "\($0.value)" } ?? "nil"), not nil")
    }

    /// The biquad state and the step sums continue across calls of `feed`.
    @Test func resultDoesNotDependOnTheFeedBlock() throws {
        let signal = tone([(10, -36), (60, -23), (10, -36)])
        let large = try #require(try measure(signal, block: 65_536).integrated)
        expectLUFS(try measure(signal, block: 1_000).integrated, large.value, tolerance: 0.001, "1 000-frame feed")
    }

    /// The shelf at 1 681.97 Hz must be under Nyquist.
    @Test func meterRefusesARateTheFilterCannotSupport() {
        #expect(LoudnessMeter(sampleRate: 3_363, layout: .stereo) == nil, "3 363 Hz gave a meter")
        #expect(LoudnessMeter(sampleRate: 3_364, layout: .stereo) != nil, "3 364 Hz gave no meter")
        #expect(LoudnessMeter(sampleRate: 8_000, layout: .stereo) != nil, "8 000 Hz gave no meter")
        #expect(LoudnessMeter(sampleRate: 0, layout: .stereo) == nil, "0 Hz gave a meter")
    }

    /// The gain scales each block, and then the gates act.
    @Test func gainActsBeforeTheGates() throws {
        let loudness = try measure(tone([(20, -65)]))
        let quieter = loudness.withGain(Gain(dB: -10)!).integrated
        #expect(quieter == nil, "gain -10 dB: read \(quieter.map { "\($0.value)" } ?? "nil"), not nil")
        expectLUFS(loudness.withGain(Gain(dB: 10)!).integrated, -55, "gain +10 dB")
    }
}
