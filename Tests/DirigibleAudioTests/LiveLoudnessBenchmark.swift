import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Run 9b criterion 8: one 100 ms step at the end of 2 h of stereo (72 000 blocks), with M, S,
/// I, and TP, takes 1 ms p95 or less, optimized (`make bench FILTER=LiveLoudnessBenchmark`; a
/// debug run only prints). The 2 h of blocks are set in the meter, not fed: a feed of 2 h takes
/// about 4 s optimized and minutes in debug. The blocks vary from -50 to -15 LUFS, so the two
/// gates keep a part of them.
struct LiveLoudnessBenchmark {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aStepAtTwoHoursFitsTheBudget() throws {
        var live = try #require(LiveLoudness(sampleRate: 48_000, layout: .stereo))
        let signal = tone([(4, -23)])
        _ = try liveValues(signal, into: &live)
        var generator = SeededGenerator(seed: 9)
        live.meter.blocks = (0..<72_000).map { _ in
            pow(10, (Double.random(in: -50 ... -15, using: &generator) + 0.691) / 10)
        }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
        fill(buffer, from: signal, start: 0, count: 4_800)

        let clock = ContinuousClock()
        var times: [Duration] = []
        for _ in 0..<200 {
            let start = clock.now
            live.feed(buffer)
            let values = live.values
            times.append(clock.now - start)
            #expect(values.integrated != nil && values.shortTerm != nil && values.truePeak != nil)
        }
        let sorted = times.sorted()
        print("bench report: a step at 2 h: p50 \(sorted[100]), p95 \(sorted[190])")
        expectWithinBudget(sorted[190], .milliseconds(1), "a step at 2 h: p95 \(sorted[190])")
    }
}
