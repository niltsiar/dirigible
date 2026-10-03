import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// A Tech 3341 true-peak case: a stereo sine of 1 s with a 10 ms fade in and fade out.
struct TruePeakCase: Sendable, CustomStringConvertible {
    let number: Int
    /// The frequency as a fraction of the rate: 4 is fs/4.
    let divisor: Double
    let amplitude: Double
    let degrees: Double
    let expected: Double

    var description: String { "case \(number)" }

    /// EBU Tech 3341 (2023) Table 1, cases 15 to 19.
    static let all = [
        TruePeakCase(number: 15, divisor: 4, amplitude: 0.5, degrees: 0, expected: -6),
        TruePeakCase(number: 16, divisor: 4, amplitude: 0.5, degrees: 45, expected: -6),
        TruePeakCase(number: 17, divisor: 6, amplitude: 0.5, degrees: 60, expected: -6),
        TruePeakCase(number: 18, divisor: 8, amplitude: 0.5, degrees: 67.5, expected: -6),
        TruePeakCase(number: 19, divisor: 4, amplitude: 1.41, degrees: 45, expected: 3),
    ]

    func signal(rate: Int) -> [[Float]] {
        let frames = rate
        let fade = Double(rate) / 100
        let samples = (0..<frames).map { index -> Float in
            let taper = min(1, Double(index) / fade, Double(frames - 1 - index) / fade)
            let phase = 2 * Double.pi * Double(index) / divisor + degrees * .pi / 180
            return Float(amplitude * taper * sin(phase))
        }
        return [samples, samples]
    }
}

/// Feeds `channels` to a new true-peak meter in blocks of the sizes of `blocks`, the last size
/// repeated, and gives the result in dBTP.
func truePeak(_ channels: [[Float]], blocks: [Int] = [65_536]) throws -> Double? {
    let layout = try #require(ChannelLayout(channelCount: channels.count))
    var meter = TruePeakMeter(layout: layout)
    let format = try #require(
        AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: AVAudioChannelCount(channels.count)))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(blocks.max()!)))
    var (start, next) = (0, 0)
    while start < channels[0].count {
        let count = min(blocks[min(next, blocks.count - 1)], channels[0].count - start)
        for (index, samples) in channels.enumerated() {
            samples.withUnsafeBufferPointer {
                buffer.floatChannelData![index].update(from: $0.baseAddress! + start, count: count)
            }
        }
        buffer.frameLength = AVAudioFrameCount(count)
        meter.feed(buffer)
        (start, next) = (start + count, next + 1)
    }
    return meter.result()
}

/// Records an issue that starts with `label` when `value` is nil or outside
/// `expected - below ... expected + above`.
func expectDBTP(
    _ value: Double?, _ expected: Double, above: Double = 0.2, below: Double = 0.4, _ label: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let near = value.map { $0 >= expected - below && $0 <= expected + above } ?? false
    #expect(
        near, "\(label): read \(value.map { "\($0)" } ?? "nil") dBTP, not \(expected)", sourceLocation: sourceLocation)
}

/// Run 9a criteria 1 to 4: the 4x FIR true-peak meter of ITU-R BS.1770-5 Annex 2 with the
/// EBU Tech 3341 (2023) cases 15 to 19, each within +0.2/-0.4 dB.
struct TruePeakTests {
    /// A sample-peak meter reads -9.03 for case 16 and -0.03 for case 19.
    @Test(arguments: TruePeakCase.all)
    func tech3341Cases15To19(_ check: TruePeakCase) throws {
        expectDBTP(try truePeak(check.signal(rate: 48_000)), check.expected, "48 kHz \(check)")
    }

    @Test(arguments: [44_100, 96_000])
    func tech3341CasesAtOtherRates(rate: Int) throws {
        for check in TruePeakCase.all {
            expectDBTP(try truePeak(check.signal(rate: rate)), check.expected, "\(rate) Hz \(check)")
        }
    }

    /// The FIR history crosses each feed edge: blocks of 65 536, 1 000, and 7 frames (shorter
    /// than the 12 taps), and one edge at frame 1 001, read the same value.
    @Test func truePeakDoesNotDependOnTheFeedBlock() throws {
        let case19 = TruePeakCase.all[4].signal(rate: 48_000)
        let whole19 = try #require(try truePeak(case19))
        expectDBTP(try truePeak(case19, blocks: [1_000]), whole19, above: 0.001, below: 0.001, "case 19 blocks 1000")
        let case16 = TruePeakCase.all[1].signal(rate: 48_000)
        let whole16 = try #require(try truePeak(case16))
        expectDBTP(
            try truePeak(case16, blocks: [1_001, 65_536]), whole16, above: 0.001, below: 0.001, "case 16 edge 1001")
        expectDBTP(try truePeak(case16, blocks: [7]), whole16, above: 0.001, below: 0.001, "case 16 blocks 7")
    }

    /// The Tech 3341 sines are symmetric in time, so they cannot tell phase 2 from phase 1. The
    /// pulse 0.5, 0.65 has its peak in one of them, and the reversed pulse in the other: probe P2
    /// reads -2.622 dBTP with the 4 phases and -3.091 with phase 1 twice. Its sample peak is -3.74. One sample of 1.0 reads 0 dBTP: the
    /// largest phase tap is 0.972 (-0.25 dB), so the meter also takes the sample itself.
    @Test func aPulseReadsTheFourPhasesAndTheSample() throws {
        let silence = [Float](repeating: 0, count: 100)
        let pulse = silence + [0.5, 0.65] + silence
        expectDBTP(try truePeak([pulse, pulse]), -2.622, above: 0.01, below: 0.01, "pulse")
        let reversed = Array(pulse.reversed())
        expectDBTP(try truePeak([reversed, reversed]), -2.622, above: 0.01, below: 0.01, "reversed pulse")
        let impulse = silence + [1] + silence
        expectDBTP(try truePeak([impulse, impulse]), 0, above: 0.001, below: 0.001, "impulse")
    }

    @Test func silenceHasNoTruePeak() throws {
        let value = try truePeak([[Float](repeating: 0, count: 48_000), [Float](repeating: 0, count: 48_000)])
        #expect(value == nil, "silence: read \(value.map { "\($0)" } ?? "nil"), not nil")
    }
}
