import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Run 8a criterion 13 (probe P2): the meter takes 1 h of stereo 48 kHz audio from memory in
/// 65 536-frame blocks (`make bench FILTER=LoudnessBenchmark`). DSP only: the file read is about
/// 0.4 s per hour (run 2026-09-25-timeline-view P1). The budget is 2x the first measured time
/// (1.88 s on the Intel Mac), rounded up to 0.5 s.
struct LoudnessBenchmark {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func oneHourStereoWithinBudget() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536))
        buffer.frameLength = 65_536
        let signal = tone([(65_536.0 / 48_000, -23)])
        for channel in 0..<2 { buffer.floatChannelData![channel].update(from: signal[channel], count: 65_536) }
        var meter = try #require(LoudnessMeter(sampleRate: 48_000, layout: .stereo))

        let clock = ContinuousClock()
        let start = clock.now
        // 2 637 x 65 536 frames = 3 600.2 s.
        for _ in 0..<2_637 { meter.feed(buffer) }
        let loudness = meter.result()
        let elapsed = clock.now - start

        print("bench report: 1 h of stereo audio took \(elapsed)")
        #expect(loudness.integrated != nil)
        expectWithinBudget(elapsed, .seconds(4), "1 h of stereo audio took \(elapsed)")
    }

    /// G1 of code gate round 1: exact zeros after a signal (a process tap with no sound) must not
    /// leave the filter state subnormal. The budget is the same as for the tone.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func oneHourOfSilenceAfterAToneWithinBudget() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let toneBuffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        toneBuffer.frameLength = 48_000
        let signal = tone([(1, -23)])
        for channel in 0..<2 { toneBuffer.floatChannelData![channel].update(from: signal[channel], count: 48_000) }
        let silence = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536))
        silence.frameLength = 65_536
        for channel in 0..<2 { silence.floatChannelData![channel].update(repeating: 0, count: 65_536) }
        var meter = try #require(LoudnessMeter(sampleRate: 48_000, layout: .stereo))

        let clock = ContinuousClock()
        let start = clock.now
        meter.feed(toneBuffer)
        for _ in 0..<2_637 { meter.feed(silence) }
        let loudness = meter.result()
        let elapsed = clock.now - start

        print("bench report: 1 s of tone and 1 h of silence took \(elapsed)")
        #expect(loudness.integrated != nil)
        expectWithinBudget(elapsed, .seconds(4), "1 s of tone and 1 h of silence took \(elapsed)")
    }
}
