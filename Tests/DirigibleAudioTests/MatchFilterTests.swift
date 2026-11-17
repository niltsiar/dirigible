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
