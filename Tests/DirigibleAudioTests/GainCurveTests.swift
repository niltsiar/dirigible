import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// A deinterleaved Float32 buffer of `channels`, all of one length.
func pcmBuffer(_ channels: [[Float]]) throws -> AVAudioPCMBuffer {
    let format = try #require(
        AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: AVAudioChannelCount(channels.count)))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(channels[0].count)))
    buffer.frameLength = AVAudioFrameCount(channels[0].count)
    for (index, samples) in channels.enumerated() {
        samples.withUnsafeBufferPointer {
            buffer.floatChannelData![index].update(from: $0.baseAddress!, count: $0.count)
        }
    }
    return buffer
}

/// The samples of channel `channel` of `buffer`.
func samples(_ buffer: AVAudioPCMBuffer, _ channel: Int = 0) -> [Float] {
    Array(UnsafeBufferPointer(start: buffer.floatChannelData![channel], count: Int(buffer.frameLength)))
}

/// The amplitude of `curve` at each frame of `frames`: the curve applied to ones.
func amplitudes(_ curve: GainCurve, _ frames: Range<Int>) throws -> [Float] {
    let buffer = try pcmBuffer([[Float](repeating: 1, count: frames.count)])
    curve.apply(to: buffer, firstFrame: frames.lowerBound)
    return samples(buffer)
}

/// C7b: the one step-to-frame map of the ride.
struct GainCurveTests {
    /// A 1 LU level step at frame 480 000: the smoothed gain is halfway between its plateaus about
    /// 0.32 step before the frame for a rise in level, and 0.32 step after it for a fall.
    @Test(arguments: [(-20.0, -19.0, 478_500), (-19.0, -20.0, 481_500)])
    func levelStepCentresOnItsFrame(before: Double, after: Double, halfway: Int) throws {
        let steps = rideSteps([(100, before), (100, after)])
        let curve = try #require(
            rideCurve(stepMeanSquares: steps, stepFrames: rideStepFrames, clips: [(0..<960_000, .zero)])?.curve)
        let middle = (curve.dB[50] + curve.dB[150]) / 2
        let frames = 450_000..<510_000
        let gains = try amplitudes(curve, frames).map { 20 * log10(Double($0)) }
        let rising = curve.dB[150] > curve.dB[50]
        let crossing = try #require(gains.indices.first { rising ? gains[$0] >= middle : gains[$0] <= middle })
        let frame = frames.lowerBound + crossing
        #expect(abs(frame - halfway) <= 1_200, "halfway at frame \(frame), not near \(halfway)")
    }

    /// Before the first centre the first gain; after the last centre the last gain, up to the last
    /// frame of a run with a partial last step.
    @Test func coversTheLastFrame() throws {
        let curve = GainCurve(dB: [0, -6], stepFrames: 100)
        let gains = try amplitudes(curve, 0..<280)
        #expect(gains[0] == 1 && gains[49] == 1)
        for frame in [150, 200, 279] {
            #expect(abs(gains[frame] - 0.501_187_23) <= 1e-6, "frame \(frame): \(gains[frame])")
        }
    }

    /// Frame k gets the amplitude of the linear ramp between the two centres around it.
    @Test func appliesAtTheFrame() throws {
        let curve = GainCurve(dB: [0, 6], stepFrames: 100)
        let gains = try amplitudes(curve, 0..<200)
        let expected: [(frame: Int, amplitude: Float)] = [
            (50, 1), (75, 1.248_815_6), (100, 1.497_631_2), (101, 1.507_583_8), (150, 1.995_262_3),
        ]
        for (frame, amplitude) in expected {
            #expect(abs(gains[frame] - amplitude) <= 1e-6, "frame \(frame): \(gains[frame]), not \(amplitude)")
        }
    }

    /// One buffer equals the same frames in two buffers that split at any frame.
    @Test func splitBuffersMatch() throws {
        var generator = SeededGenerator(seed: 7)
        let curve = GainCurve(dB: (0..<20).map { _ in Double.random(in: -6...6, using: &generator) }, stepFrames: 4_800)
        let signal = (0..<96_000).map { _ in Float.random(in: -0.4...0.4, using: &generator) }
        let whole = try pcmBuffer([signal])
        curve.apply(to: whole, firstFrame: 0)
        let expected = samples(whole)
        for split in [1, 2_399, 2_400, 2_401, 4_800, 33_333, 95_999] {
            let first = try pcmBuffer([Array(signal[..<split])])
            let second = try pcmBuffer([Array(signal[split...])])
            curve.apply(to: first, firstFrame: 0)
            curve.apply(to: second, firstFrame: split)
            let parts = samples(first) + samples(second)
            let largest = zip(parts, expected).map { abs($0 - $1) }.max()!
            #expect(largest <= 1e-7, "split at \(split): a difference of \(largest)")
        }
    }

    /// Each channel gets the same gain at each frame.
    @Test func channelsShareTheGain() throws {
        let curve = GainCurve(dB: [-6, 4, 0], stepFrames: 1_000)
        let left = [Float](repeating: 0.25, count: 3_000)
        let right = (0..<3_000).map { Float(0.5 * sin(Double($0) * 0.05)) }
        let buffer = try pcmBuffer([left, right])
        curve.apply(to: buffer, firstFrame: 0)
        let gains = try amplitudes(curve, 0..<3_000)
        let leftMatches = zip(samples(buffer, 0), gains).allSatisfy { abs($0 - 0.25 * $1) <= 1e-7 }
        let rightMatches = zip(samples(buffer, 1), zip(right, gains)).allSatisfy { abs($0 - $1.0 * $1.1) <= 1e-7 }
        #expect(leftMatches && rightMatches)
        #expect(gains[500] != gains[1_500], "control: the gain moves")
    }
}
