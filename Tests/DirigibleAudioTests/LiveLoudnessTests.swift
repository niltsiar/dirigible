import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Copies frames `start..<start + count` of `channels` into `buffer`.
func fill(_ buffer: AVAudioPCMBuffer, from channels: [[Float]], start: Int, count: Int) {
    for (index, samples) in channels.enumerated() {
        samples.withUnsafeBufferPointer {
            buffer.floatChannelData![index].update(from: $0.baseAddress! + start, count: count)
        }
    }
    buffer.frameLength = AVAudioFrameCount(count)
}

/// Feeds `channels` to `live` in blocks of `block` frames and gives the values after each block.
func liveValues(
    _ channels: [[Float]], into live: inout LiveLoudness, rate: Int = 48_000, block: Int = 4_800
) throws -> [LoudnessValues] {
    let format = try #require(
        AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: AVAudioChannelCount(channels.count)))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(block)))
    var values: [LoudnessValues] = []
    var start = 0
    while start < channels[0].count {
        let count = min(block, channels[0].count - start)
        fill(buffer, from: channels, start: start, count: count)
        live.feed(buffer)
        values.append(live.values)
        start += count
    }
    return values
}

/// The values after each 100 ms step of a new stereo meter at 48 kHz.
func liveSteps(_ channels: [[Float]]) throws -> [LoudnessValues] {
    var live = try #require(LiveLoudness(sampleRate: 48_000, layout: .stereo))
    return try liveValues(channels, into: &live)
}

/// Run 9b criteria 1 to 7 and 13: momentary (400 ms) and short-term (3 s) loudness of EBU Tech
/// 3341, and the live meter of the play. Step i (from 1) ends at i x 0.1 s.
struct LiveLoudnessTests {
    /// Checks `value` of each step whose end is at or after `from` seconds.
    func expectEachStep(
        _ steps: [LoudnessValues], from: Double, _ value: (LoudnessValues) -> LUFS?, _ expected: Double,
        _ label: String, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let first = Int((from * 10).rounded()) - 1
        for index in first..<steps.count {
            expectLUFS(
                value(steps[index]), expected, "\(label) at \(Double(index + 1) / 10) s", sourceLocation: sourceLocation
            )
        }
    }

    /// With no -0.691 offset, the values read -22.30.
    @Test func cases1And2() throws {
        for level in [-23.0, -33.0] {
            let steps = try liveSteps(tone([(20, level)]))
            expectEachStep(steps, from: 0.4, \.momentary, level, "M of case \(level)")
            expectEachStep(steps, from: 3, \.shortTerm, level, "S of case \(level)")
        }
    }

    /// Case 9: 5 x (1.34 s at -20, 1.66 s at -30 dBFS). A 4 s window reads -23.96 at its lowest
    /// and a 2 s window -25.96 (probe M1).
    @Test func case9ShortTerm() throws {
        let steps = try liveSteps(tone(Array(repeating: [(1.34, -20), (1.66, -30)], count: 5).flatMap { $0 }))
        expectEachStep(steps, from: 3, \.shortTerm, -23, "S of case 9")
    }

    /// Case 12: 25 x (0.18 s at -20, 0.22 s at -30 dBFS). A 300 ms window reads -24.68 and a
    /// 500 ms window -23.72 (probe M1).
    @Test func case12Momentary() throws {
        let steps = try liveSteps(tone(Array(repeating: [(0.18, -20), (0.22, -30)], count: 25).flatMap { $0 }))
        expectEachStep(steps, from: 0.4, \.momentary, -23, "M of case 12")
    }

    @Test func noValueBeforeTheWindowFills() throws {
        let steps = try liveSteps(tone([(4, -23)]))
        let earlyM = steps[0..<3].compactMap(\.momentary)
        #expect(earlyM.isEmpty, "M before 0.4 s: \(earlyM)")
        let earlyS = steps[0..<29].compactMap(\.shortTerm)
        #expect(earlyS.isEmpty, "S before 3 s: \(earlyS)")
        #expect(steps[3].momentary != nil, "M at 0.4 s is nil")
        #expect(steps[29].shortTerm != nil, "S at 3 s is nil")

        let silence = try liveSteps(tone([(5, -.infinity)]))
        let last = try #require(silence.last)
        #expect(
            last.momentary == nil && last.shortTerm == nil && last.integrated == nil && last.truePeak == nil,
            "5 s of zeros: \(last)")
    }

    /// One NaN sample at 5.0 s counts as silence for its step, and the meter goes on. The export
    /// rule of run 8a stays: `result()` of the same meter has no integrated value.
    @Test func aNaNSampleCountsAsSilence() throws {
        var signal = tone([(10, -23)])
        signal[0][240_000] = .nan
        var live = try #require(LiveLoudness(sampleRate: 48_000, layout: .stereo))
        let steps = try liveValues(signal, into: &live)
        let notFinite = steps.flatMap { [$0.momentary, $0.shortTerm] }.compactMap { $0 }.filter { !$0.value.isFinite }
        #expect(notFinite.isEmpty, "M or S not finite: \(notFinite.count) values")
        let filled = steps[3...].allSatisfy { $0.momentary != nil } && steps[29...].allSatisfy { $0.shortTerm != nil }
        #expect(filled, "M or S nil after the NaN")
        expectEachStep(steps, from: 8.6, \.momentary, -23, "M after the NaN")
        expectEachStep(steps, from: 8.6, \.shortTerm, -23, "S after the NaN")
        expectLUFS(steps[48].integrated, -23, "I at 4.9 s")
        let integrated = steps[50...].compactMap(\.integrated)
        #expect(integrated.isEmpty, "I after the NaN: \(integrated)")
        #expect(live.meter.result().integrated == nil, "result() after a NaN has an integrated value")

        live.reset()
        let after = try liveValues(tone([(1, -23)]), into: &live)
        expectLUFS(after.last?.integrated, -23, "I after a reset and 1 s")
    }

    /// The values change only when a step completes, so a feed of 1 000 frames that ends at
    /// frame f equals the feed of 4 800 frames at step floor(f / 4 800).
    @Test func stepsDoNotDependOnTheFeedBlock() throws {
        let signal = tone(Array(repeating: [(1.34, -20), (1.66, -30)], count: 5).flatMap { $0 })
        let large = try liveSteps(signal)
        var live = try #require(LiveLoudness(sampleRate: 48_000, layout: .stereo))
        let small = try liveValues(signal, into: &live, block: 1_000)
        var worst = 0.0
        for (index, value) in small.enumerated() {
            let step = (index + 1) * 1_000 / 4_800
            let reference = step == 0 ? LoudnessValues.none : large[step - 1]
            for (a, b) in [
                (value.momentary, reference.momentary), (value.shortTerm, reference.shortTerm),
                (value.integrated, reference.integrated),
            ] {
                switch (a, b) {
                case (nil, nil): continue
                case (let a?, let b?): worst = max(worst, abs(a.value - b.value))
                default: worst = .infinity
                }
            }
        }
        #expect(worst <= 1e-9, "the 1 000-frame feed differs by \(worst) LU")
    }

    /// The 8a fixtures of `LoudnessTests` cases 3, 4, and 5.
    @Test func liveIntegratedEqualsTheMeter() throws {
        let fixtures = [
            tone([(10, -36), (60, -23), (10, -36)]),
            tone([(10, -72), (10, -36), (60, -23), (10, -36), (10, -72)]),
            tone([(20, -26), (20.1, -20), (20, -26)]),
        ]
        for (index, signal) in fixtures.enumerated() {
            var live = try #require(LiveLoudness(sampleRate: 48_000, layout: .stereo))
            let steps = try liveValues(signal, into: &live, block: 65_536)
            let expected = try #require(try measure(signal).integrated)
            expectLUFS(steps.last?.integrated, expected.value, tolerance: 0.001, "fixture \(index + 3)")
        }
    }

    /// Tech 3341 case 19 reads +3.0 dBTP; a sample-peak meter reads -0.03.
    @Test func truePeakMaxAndReset() throws {
        var live = try #require(LiveLoudness(sampleRate: 48_000, layout: .stereo))
        let signal = try #require(TruePeakCase.all.last).signal(rate: 48_000)
        _ = try liveValues(signal, into: &live)
        expectDBTP(live.values.truePeak, 3, "case 19")
        #expect(live.values.integrated != nil, "case 19 has no integrated value")
        live.reset()
        #expect(live.values == .none, "after reset: \(live.values)")
        _ = try liveValues(tone([(1, -23)]), into: &live)
        expectDBTP(live.values.truePeak, -23, "TP after a reset and 1 s at -23 dBFS")
    }

    /// The two gates at their edges, with literal values. Criterion 6 compares two meters with
    /// one gate, so it cannot see a wrong gate. The relative gate of a 10 s part at -23 and a
    /// 10 s part at -35 is -35.75 LUFS, and at -36.3 it is -35.81.
    @Test func gatesHoldAtTheirEdges() throws {
        let under = try liveSteps(tone([(2, -70.3)])).last?.integrated
        #expect(under == nil, "I of -70.3: read \(under.map { "\($0.value)" } ?? "nil"), not nil")
        expectLUFS(try liveSteps(tone([(2, -69.7)])).last?.integrated, -69.7, "I of -69.7")
        expectLUFS(try liveSteps(tone([(10, -23), (10, -35)])).last?.integrated, -25.74, "I of -23 and -35")
        expectLUFS(try liveSteps(tone([(10, -23), (10, -36.3)])).last?.integrated, -23, "I of -23 and -36.3")
    }

    /// Run 9b criterion 13: the interleaved feed of the record path equals the buffer feed.
    @Test func interleavedFeedEqualsBufferFeed() throws {
        // The channels differ, so a feed that reads one channel twice reads another value.
        let signal = [
            tone(Array(repeating: [(1.34, -20), (1.66, -30)], count: 5).flatMap { $0 })[0], tone([(15, -30)])[0],
        ]
        var deinterleaved = try #require(LoudnessMeter(sampleRate: 48_000, layout: .stereo))
        var interleaved = deinterleaved
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_000))
        var worst = 0.0
        var start = 0
        while start < signal[0].count {
            let count = min(1_000, signal[0].count - start)
            fill(buffer, from: signal, start: start, count: count)
            deinterleaved.feed(buffer)
            let frames = (start..<start + count).flatMap { [signal[0][$0], signal[1][$0]] }
            frames.withUnsafeBufferPointer { interleaved.feed(interleaved: $0) }
            for (a, b) in [
                (deinterleaved.momentary, interleaved.momentary), (deinterleaved.shortTerm, interleaved.shortTerm),
            ] {
                switch (a, b) {
                case (nil, nil): continue
                case (let a?, let b?): worst = max(worst, abs(a.value - b.value))
                default: worst = .infinity
                }
            }
            start += count
        }
        let (a, b) = (deinterleaved.result().integrated, interleaved.result().integrated)
        worst = max(worst, a.flatMap { a in b.map { abs(a.value - $0.value) } } ?? .infinity)
        #expect(worst <= 1e-9, "the interleaved feed differs by \(worst) LU")
    }
}
