import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The output of `filter` for a unit impulse: the kernel taps, as the stage applies them.
func impulseResponse(_ filter: MatchFilter, _ kernel: MatchFilter.Kernel) -> [Float] {
    let context = filter.contextFrames
    var input = [Float](repeating: 0, count: filter.taps + 2 * context)
    input[2 * context] = 1
    var output = [Float](repeating: 0, count: filter.taps)
    input.withUnsafeBufferPointer { source in
        output.withUnsafeMutableBufferPointer { filter.filter(source, through: kernel, into: $0) }
    }
    return output
}

/// The magnitude in dB of the response `taps` at `frequency`, from its discrete-time Fourier
/// transform in Double.
private func magnitude(_ taps: [Float], at frequency: Double, rate: Int) -> Double {
    let step = 2 * Double.pi * frequency / Double(rate)
    var real = 0.0
    var imaginary = 0.0
    for (index, tap) in taps.enumerated() {
        real += Double(tap) * cos(step * Double(index))
        imaginary -= Double(tap) * sin(step * Double(index))
    }
    return 10 * log10(real * real + imaginary * imaginary)
}

private func gains(_ values: [Double]) throws -> ThirdOctave.Gains {
    try #require(ThirdOctave.Gains(decibels: values))
}

/// The band powers of 48 kHz mono `samples` as `BandAnalyzer` measures them, summed over its frames.
private func bandPowers(_ samples: [Float]) throws -> [Double] {
    let analyzer = BandAnalyzer(sampleRate: 48_000)
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
    var filled = false
    let read = try #require(
        analyzer.read(buffer, layout: .mono) { buffer in
            guard !filled else { return false }
            filled = true
            samples.withUnsafeBufferPointer {
                buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count)
            }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            return true
        })
    return (0..<ThirdOctave.bandCount).map { band in
        stride(from: band, to: read.frames.count, by: ThirdOctave.bandCount).reduce(0) { $0 + read.frames[$1] }
    }
}

/// The curves of criterion C1: a tilt from -12 dB at 63 Hz to +12 dB at 16 kHz, +12 dB at 1 kHz
/// only, -12 dB at 80 Hz only, and the mirror tilt.
private let tilt = (0..<25).map { -12 + Double($0) }
private let mirrorTilt = tilt.map { -$0 }
private let peakAt1k = (0..<25).map { $0 == 12 ? 12.0 : 0 }
private let notchAt80 = (0..<25).map { $0 == 1 ? -12.0 : 0 }
private let curves = [("tilt", tilt), ("+12 dB at 1 kHz", peakAt1k), ("-12 dB at 80 Hz", notchAt80)]

/// The rates of C1, each with the taps of the rate rule of decision 0074 D2.
private let rates = [(44_100, 16_385), (48_000, 16_385), (96_000, 32_769)]

@Suite struct MatchFilterTests {
    @Test func responseMeetsTheCurve() throws {
        var errors: [String] = []
        for (rate, taps) in rates {
            let filter = MatchFilter(sampleRate: rate)
            #expect(filter.taps == taps, "taps at \(rate) Hz")
            for (name, curve) in curves {
                let response = impulseResponse(filter, filter.kernel(try gains(curve)))
                for (band, center) in ThirdOctave.centers.enumerated() {
                    let error = abs(magnitude(response, at: center, rate: rate) - curve[band])
                    if error > (band < 2 ? 1.5 : 1.0) {
                        errors.append("\(rate) Hz, \(name), \(center) Hz: \(String(format: "%.2f", error)) dB")
                    }
                }
            }
        }
        if !errors.isEmpty { print("band errors:\n" + errors.joined(separator: "\n")) }
        let meetsTheCurve = errors.isEmpty
        #expect(meetsTheCurve, "\(errors.count) band errors over the C1 bound")
    }

    /// A narrow cut delivers its band gain (C9): the band power gain that `BandAnalyzer` measures
    /// through the filter is within 1.0 dB of each band gain, on noise with the slope of a voice.
    /// C9 allows 1.5 dB in each band; on its corpus voices the learn and the measure take 0.17 dB
    /// at most, so 1.0 dB here leaves C9 a margin of 0.33 dB.
    @Test func narrowCutDeliversItsBandGain() throws {
        let filter = MatchFilter(sampleRate: 48_000)
        let curve = (0..<25).map { $0 == 19 ? -8.0 : 0 }
        let kernel = filter.kernel(try gains(curve))
        // White noise through a one-pole low-pass at 500 Hz: -6 dB per octave over 500 Hz.
        var random = SeededGenerator(seed: 9)
        let pole = Float(exp(-2 * Double.pi * 500 / 48_000))
        var level: Float = 0
        let frames = 4 * 48_000
        let input = (0..<(frames + filter.taps - 1)).map { _ in
            level = pole * level + (1 - pole) * Float.random(in: -1...1, using: &random)
            return level
        }
        var output = [Float](repeating: 0, count: frames)
        input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { filter.filter(source, through: kernel, into: $0) }
        }
        let plain = try bandPowers(Array(input[filter.contextFrames..<filter.contextFrames + frames]))
        let heard = try bandPowers(output)
        var errors: [String] = []
        for (band, center) in ThirdOctave.centers.enumerated() {
            let delivered = 10 * log10(heard[band] / plain[band])
            if abs(delivered - curve[band]) > 1.0 {
                errors.append("\(center) Hz: \(String(format: "%.2f", delivered)) dB for \(curve[band]) dB")
            }
        }
        if !errors.isEmpty { print("band power errors:\n" + errors.joined(separator: "\n")) }
        let delivers = errors.isEmpty
        #expect(delivers, "\(errors.count) bands over 1.0 dB from the curve")
    }

    /// No boost lies outside the band range, and a cut at 63 Hz ends at 28.1 Hz.
    @Test func outOfBandIsFlat() throws {
        // (curve, frequency, expected dB, bound)
        let points = [
            (tilt, 20.0, 0.0, 0.5), (tilt, 18_000, 0, 0.5), (mirrorTilt, 63, 12, 1.5), (mirrorTilt, 20, 0, 0.5),
            (mirrorTilt, 31.5, 0, 0.5), (mirrorTilt, 40, 0, 0.5),
        ]
        var errors: [String] = []
        for (rate, _) in rates {
            let filter = MatchFilter(sampleRate: rate)
            for (curve, frequency, expected, bound) in points {
                let response = impulseResponse(filter, filter.kernel(try gains(curve)))
                let value = magnitude(response, at: frequency, rate: rate)
                if abs(value - expected) > bound {
                    errors.append("\(rate) Hz, \(frequency) Hz: \(String(format: "%.2f", value)) dB")
                }
            }
        }
        if !errors.isEmpty { print("out-of-band errors:\n" + errors.joined(separator: "\n")) }
        let flat = errors.isEmpty
        #expect(flat, "\(errors.count) out-of-band points off 0 dB or the end band")
    }

    /// A zero curve gives the input frames, over several blocks and a partial last block.
    @Test func zeroCurveKeepsTheInput() throws {
        let filter = MatchFilter(sampleRate: 48_000)
        let kernel = filter.kernel(try gains(Array(repeating: 0, count: 25)))
        var random = SeededGenerator(seed: 74)
        let frames = 40_000
        let input = (0..<(frames + filter.taps - 1)).map { _ in Float.random(in: -1...1, using: &random) }
        var output = [Float](repeating: 0, count: frames)
        input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { filter.filter(source, through: kernel, into: $0) }
        }
        let largest = zip(output, input[filter.contextFrames...]).map { abs($0 - $1) }.max() ?? .infinity
        #expect(largest <= 1e-6, "largest difference \(largest)")
    }

    /// At 32 kHz the bands at and over 0.45 x the rate (14.4 kHz) get 0 dB, and the bands under
    /// it keep their gain.
    @Test func bandsOverTheLimitAreFlat() throws {
        let filter = MatchFilter(sampleRate: 32_000)
        #expect(filter.taps == 16_385)
        let response = impulseResponse(filter, filter.kernel(try gains(Array(repeating: 12, count: 25))))
        let underTheLimit = magnitude(response, at: 12_500, rate: 32_000)
        let overTheLimit = [15_000.0, 15_900].map { magnitude(response, at: $0, rate: 32_000) }
        #expect(abs(underTheLimit - 12) <= 1.0, "12.5 kHz: \(underTheLimit) dB")
        #expect(overTheLimit.allSatisfy { abs($0) <= 0.5 }, "15 and 15.9 kHz: \(overTheLimit) dB")
    }

    /// Logs P - G for the C1 curves (criterion C25): P is the sum of the absolute taps, the bound
    /// of the output peak for any input peak of 1, and G is the largest band gain.
    @Test func peakGainIsLogged() throws {
        let filter = MatchFilter(sampleRate: 48_000)
        for (name, curve) in curves {
            let response = impulseResponse(filter, filter.kernel(try gains(curve)))
            let sum = response.reduce(0.0) { $0 + Double(abs($1)) }
            let peak = 20 * log10(sum)
            let largest = curve.max() ?? 0
            print(
                "peak gain \(name): P \(String(format: "%.2f", peak)) dB, G \(String(format: "%.2f", largest)) dB, "
                    + "P - G \(String(format: "%.2f", peak - largest)) dB")
            // The sum of the absolute taps bounds the response at each frequency.
            let responses = ThirdOctave.centers.map { magnitude(response, at: $0, rate: 48_000) }
            #expect(peak >= (responses.max() ?? .infinity) - 1e-9, "\(name): P under the largest response")
        }
    }
}
