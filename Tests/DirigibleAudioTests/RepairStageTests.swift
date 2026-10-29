import Foundation
import Testing

@testable import DirigibleAudio

/// The repair stages of the clip render (decision 0064 D1, D3, D5): the high-pass and the de-ess
/// here, the de-clip in `RepairStageTests+Declip.swift`. The fixture values come from the float64
/// ports of `probe-s1` of the run, on the same fixtures and seeds.
struct RepairStageTests {
    /// C1: the 80 Hz high-pass at 48 kHz on sines of 0.5, the RMS of the second second: -3.01 dB
    /// +-0.05 at 80 Hz, -12.0 dB or less at 40 Hz, within 0.05 dB at 300 Hz and 1 kHz. Fail: a
    /// 1st-order filter (about -7 dB at 40 Hz).
    @Test func rumbleResponse() {
        var gains: [Double: Double] = [:]
        for hertz in [80.0, 40, 300, 1_000] {
            var stage = RumbleStage(hertz: 80, rate: 48_000, channels: 1)
            let sine = (0..<96_000).map { Float(0.5 * sin(2 * .pi * hertz * Double($0) / 48_000)) }
            let output = render(&stage, [sine])[0]
            gains[hertz] = rmsDecibels(output, from: 48_000) - rmsDecibels(sine, from: 48_000)
        }

        let label = "\(gains.sorted { $0.key < $1.key })"
        #expect(abs(gains[80, default: 0] + 3.01) <= 0.05, "80 Hz; \(label)")
        #expect(gains[40, default: 0] <= -12.0, "40 Hz; \(label)")
        for hertz in [300.0, 1_000] { #expect(abs(gains[hertz, default: 99]) <= 0.05, "\(hertz) Hz; \(label)") }
    }

    /// C1: the high-pass keeps its state across blocks: blocks of 65,536 frames, and blocks of odd
    /// sizes, equal one pass to 1e-6 on both channels. Fail: a filter that resets at each block
    /// (a step of the 0.2 offset at each block start).
    @Test func rumbleAcrossBlocks() {
        let frames = 3 * 65_536 + 1_000
        let noise = seededNoise(frames: frames, level: 0.05, seed: 64)
        let left = (0..<frames).map { 0.2 + 0.4 * Float(sin(2 * .pi * 50 * Double($0) / 48_000)) + noise[$0] }
        let input = [left, Array(left.reversed())]
        var whole = RumbleStage(hertz: 80, rate: 48_000, channels: 2)
        let expected = render(&whole, input, blocks: [frames])

        for blocks in [[65_536], [1_000, 4_096, 65_529, 37]] {
            var stage = RumbleStage(hertz: 80, rate: 48_000, channels: 2)
            let output = render(&stage, input, blocks: blocks)
            let changes = zip(expected.joined(), output.joined()).map { abs($0 - $1) }
            let worst = changes.indices.max { changes[$0] < changes[$1] } ?? 0
            let (difference, counts) = (changes[worst], output.map { $0.count })
            let label = "blocks \(blocks): \(difference) at frame \(worst % frames) of channel \(worst / frames)"
            #expect(counts == [frames, frames] && difference <= 1e-6, "\(label)")
        }
    }

    /// C5: on the first vowel (harmonics to 7,920 Hz, onset included) the output equals the input
    /// in each frame; the "s" is cut; from 181.3 ms after the "s" ends (frame 39,903), the second
    /// vowel equals the input again (the 60 ms release holds the cut to 130.0 ms in the probe).
    /// Fail: a threshold of -15 dB (2.49 dB cut on the first vowel), a 120 ms release (cut to
    /// 261.1 ms).
    @Test func deessNullOnAVowel() {
        let input = sibilantSpeech()
        var stage = DeEssStage(hertz: 6_000, decibels: 10, rate: 48_000, channels: 1)
        let output = render(&stage, [input])[0]

        let change = zip(input, output).map { abs($0 - $1) }
        #expect(change[24_000..<31_200].max() ?? 0 > 0.01, "the s is not cut")
        #expect(change[..<24_000].max() == 0, "first vowel: \(change[..<24_000].max() ?? -1)")
        let last = (31_200..<55_200).last { change[$0] != 0 }
        #expect(change[39_903...].max() == 0, "second vowel: last change at frame \(last ?? -1)")
    }

    /// C5: the mean cut of the "s" at the standard 10 dB is 9 dB or more (probe: 9.89 dB), and no
    /// frame is cut by more than 10 dB. Fail: the -6 dB threshold (5.9 dB).
    @Test func deessCutsTheBurst() {
        let input = sibilantSpeech()
        var stage = DeEssStage(hertz: 6_000, decibels: 10, rate: 48_000, channels: 1)
        let output = render(&stage, [input])[0]

        let cuts = deessCuts(input, output, minimum: 0.01).filter { (24_000..<31_200).contains($0.key) }.map(\.value)
        let mean = cuts.reduce(0, +) / Double(max(1, cuts.count))
        #expect(cuts.count >= 5_000 && mean >= 9, "\(cuts.count) frames, mean cut \(mean) dB")
        #expect(cuts.max() ?? 99 <= 10.01, "max cut \(cuts.max() ?? -1) dB")
    }

    /// C5: the cut does not follow the file level: the speech at -6 and at -26 dBFS gets the same
    /// cut in each frame, to 0.01 dB. Fail: the absolute detector of SoundCraft (-30 dBFS), which
    /// cuts 19.0 % of the frames at -6 dBFS and none at -26 dBFS.
    @Test func deessFollowsNoLevel() {
        let speech = sibilantSpeech()
        let peak = Double(largest(speech))
        var cuts: [[Int: Double]] = []
        for target in [0.5, 0.05] {
            let input = speech.map { Float(Double($0) / peak * target) }
            var stage = DeEssStage(hertz: 6_000, decibels: 10, rate: 48_000, channels: 1)
            cuts.append(deessCuts(input, render(&stage, [input])[0], minimum: target * 2e-2))
        }

        let pairs = cuts[1].compactMap { frame, quiet in cuts[0][frame].map { (loud: $0, quiet: quiet) } }
        let worst = pairs.map { abs($0.loud - $0.quiet) }.max() ?? 99
        let most = pairs.map(\.loud).max() ?? 0
        #expect(pairs.count >= 1_000 && most >= 9 && worst <= 0.01, "\(pairs.count) frames, max \(most), diff \(worst)")
    }

    /// C5: digital silence passes unchanged: no non-finite sample, the leading 0.5 s of zeros stays
    /// zeros, and the gap stays zeros from 1 s after the first burst. Fail: no rule for silence (a
    /// NaN at frame 0 from -inf minus -inf).
    @Test func deessKeepsDigitalSilence() {
        let burst = (sibilantVowel(frames: 9_600, start: 0) + sibilantBurst()).map { Float($0) }
        let input = [Float](repeating: 0, count: 24_000) + burst + [Float](repeating: 0, count: 96_000) + burst
        let end = 24_000 + burst.count
        var stage = DeEssStage(hertz: 6_000, decibels: 10, rate: 48_000, channels: 1)
        let output = render(&stage, [input])[0]

        let finite = output.allSatisfy { $0.isFinite }
        #expect(finite, "first non-finite at \(output.firstIndex { !$0.isFinite } ?? -1)")
        let cut = zip(input[24_000..<end], output[24_000..<end]).map { abs($0 - $1) }.max() ?? 0
        let leading = output[..<24_000].allSatisfy { $0 == 0 }
        let gap = output[(end + 48_000)..<(end + 96_000)].allSatisfy { $0 == 0 }
        #expect(cut > 0.01, "no cut")
        #expect(leading, "leading zeros changed")
        #expect(gap, "gap changed")
    }

    /// C5: one gain for all channels, from the loudest channel: the left channel (vowel, "s",
    /// vowel) gets the cut of a mono stage, and the right channel (the vowel at 0.1, no "s") gets
    /// the same gain during the "s". Fail: a gain for each channel, which leaves the right channel
    /// as it is.
    @Test func deessLinksTheChannels() {
        let left = sibilantSpeech()
        let right = sibilantVowel(frames: left.count, start: 0).map { Float(0.1 * $0) }
        var mono = DeEssStage(hertz: 6_000, decibels: 10, rate: 48_000, channels: 1)
        let alone = render(&mono, [left])[0]
        var stereo = DeEssStage(hertz: 6_000, decibels: 10, rate: 48_000, channels: 2)
        let output = render(&stereo, [left, right])

        let leftChange = zip(alone, output[0]).map { abs($0 - $1) }.max() ?? 1
        let rightCut = zip(right[24_000..<31_200], output[1][24_000..<31_200]).map { abs($0 - $1) }.max() ?? 0
        #expect(leftChange <= 1e-6, "left differs from the mono stage by \(leftChange)")
        #expect(rightCut > 1e-5, "right channel in the s: max change \(rightCut)")
        let rightKept = output[1][..<24_000] == right[..<24_000]
        #expect(rightKept, "right channel changed in the first vowel")
    }

    /// C15: after each `process` call, each stage holds at most its latency in frames (484 for the
    /// de-clip at 48 kHz, 0 for the others) and gives as many frames as it took. Fail: a stage that
    /// keeps the whole span.
    @Test func stageHoldsAtMostItsLatency() {
        let vowel = clipped(swingVowel(120), over: 2).clipped
        let input = Array(Array(repeating: vowel, count: 5).joined())
        var declip = DeclipStage(percent: 99, peaks: [1], carriedBits: 24, rate: 48_000)
        var rumble = RumbleStage(hertz: 80, rate: 48_000, channels: 1)
        var deess = DeEssStage(hertz: 6_000, decibels: 10, rate: 48_000, channels: 1)

        let results = [Self.held(&declip, input), Self.held(&rumble, input), Self.held(&deess, input)]
        #expect(declip.latency == 484)
        let (worst, sizesMatch) = (results.map { $0.worst }, results.allSatisfy { $0.sizesMatch })
        #expect(worst == [484, 0, 0] && sizesMatch, "\(results)")
    }

    /// The most frames that `stage` held after a `process` call, over `input` in blocks of 65,536,
    /// 1, 4,096, and 37 frames, and whether each call gave as many frames as it took.
    static func held<Stage: RenderStage>(_ stage: inout Stage, _ input: [Float]) -> (worst: Int, sizesMatch: Bool) {
        var (start, index, worst, sizesMatch) = (0, 0, 0, true)
        let sizes = [65_536, 1, 4_096, 37]
        while start < input.count {
            let count = min(sizes[index % sizes.count], input.count - start)
            let output = stage.process([Array(input[start..<start + count])])
            sizesMatch = sizesMatch && output[0].count == count
            worst = max(worst, stage.held)
            (start, index) = (start + count, index + 1)
        }
        return (worst, sizesMatch)
    }
}
