import Foundation
import Testing

@testable import DirigibleAudio

/// The de-clip stage (decision 0064 D4; C2 to C4), on the U5g vowels and steady tones of
/// `RepairFixtures.swift`.
extension RepairStageTests {
    /// The runs of 3 or more frames in a row at full scale of `samples`.
    static func clipRuns(_ samples: [Float]) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var start: Int?
        for index in 0...samples.count {
            let flat = index < samples.count && abs(samples[index]) >= 1
            if flat, start == nil { start = index }
            if !flat, let first = start {
                if index - first >= 3 { runs.append(first..<index) }
                start = nil
            }
        }
        return runs
    }

    /// A de-clip stage at the standard 99 % for one channel of peak `peak`.
    static func declip(peak: Float, bits: Int = 24, rate: Double = 48_000) -> DeclipStage {
        DeclipStage(percent: 99, peaks: [peak], carriedBits: bits, rate: rate)
    }

    /// C3 on the U5g vowels (120 and 220 Hz, steady and with a 3 Hz level swing of 25 %): at 6 dB
    /// over, the error of the clipped samples is 2 dB or more under the clip error (probe: -3.50,
    /// -4.26, and -2.36 dB), and 1.8 dB or more for the steady 220 Hz vowel, a known limit of C3
    /// (probe: -1.91 dB); at 3 dB over, 0.5 dB or more (probe: -8.97 to -17.74 dB). Each clipped
    /// sample keeps at least the clip level. Fail: a flat fill (0.00 dB).
    @Test(arguments: [(120.0, 0.0), (120, 0.25), (220, 0), (220, 0.25)])
    func declipRestoresTheVowel(f0: Double, swing: Double) {
        let limit = f0 == 220 && swing == 0 ? -1.8 : -2.0
        for (over, bar) in [(2.0, limit), (1.41, -0.5)] {
            let (truth, input) = clipped(swingVowel(f0, swing: swing), over: over)
            var stage = Self.declip(peak: largest(input))
            let output = render(&stage, [input])[0]

            let error = clipErrorDecibels(truth: truth, clipped: input, output: output)
            let lower = input.indices.filter { abs(input[$0]) >= 1 && abs(output[$0]) < 1 }.count
            let label = "x\(over): \(stage.runs) runs, \(error) dB, \(lower) samples under the clip"
            #expect(stage.runs >= 100 && error <= bar && lower == 0, "\(label)")
        }
    }

    /// C3: the 16-bit and 24-bit dithered vowels at clip level 0.891 (6 dB over, TPDF, seed 1) keep
    /// 95 % or more of the runs that the float source gives (probe: 100 %). Fail: the 1e-6 term
    /// alone at 16 bits (probe: 14.8 to 24.6 %).
    @Test(arguments: [(120.0, 16), (120, 24), (220, 16), (220, 24)])
    func declipFindsDitheredRuns(f0: Double, bits: Int) {
        let source = clipped(swingVowel(f0), over: 2).clipped.map { Float(Double($0) * 0.891) }
        var reference = Self.declip(peak: largest(source))
        let runs = changedRanges(source, render(&reference, [source])[0])
        let input = dithered(source.map(Double.init), bits: bits, seed: 1)
        var stage = Self.declip(peak: largest(input), bits: bits)
        let changed = changedRanges(input, render(&stage, [input])[0])

        let found = runs.filter { run in changed.contains { $0.overlaps(run) } }.count
        #expect(runs.count >= 200 && Double(found) >= 0.95 * Double(runs.count), "\(found) of \(runs.count)")
    }

    /// C2: clean audio keeps each sample: the U5g vowels at a peak of 1.0 with no clip, and a span of
    /// digital silence (peak 0), give 0 runs and the input. Fail: the Phase 1 detector with no
    /// flatness test (probe-s1 H: 21 runs in the 120 Hz vowel, max change 0.0122).
    @Test func declipLeavesCleanAudio() {
        let inputs = [swingVowel(120), swingVowel(220), [Double](repeating: 0, count: 4_800)]
        for input in inputs.map({ samples in samples.map { Float($0) } }) {
            var stage = Self.declip(peak: largest(input))
            let kept = render(&stage, [input])[0] == input
            #expect(stage.runs == 0 && kept, "peak \(largest(input)): \(stage.runs) runs")
        }
    }

    /// C2: sines at full peak (1 s) at crest offsets 0, 1/3, and 1/2 of a sample keep each sample:
    /// as float32 and as 24-bit TPDF PCM for 20 to 400 Hz at 48 kHz and 30 to 400 Hz at 96 kHz, as
    /// 16-bit TPDF PCM for 200 and 400 Hz at 48 kHz and 400 Hz at 96 kHz, and the 16-bit 100 Hz sine
    /// at 48 kHz at 0.1234 rad. Fail: no flatness test (120 runs in the 60 Hz sine), and 4 LSB at 16
    /// bits (probe-s1 D: 16 runs in that 100 Hz sine).
    @Test(arguments: [
        (48_000.0, 20.0), (48_000, 30), (48_000, 60), (48_000, 100), (48_000, 200), (48_000, 400),
        (96_000, 30), (96_000, 60), (96_000, 100), (96_000, 200), (96_000, 400),
    ])
    func declipLeavesASteadyTone(rate: Double, hertz: Double) {
        var forms: [(name: String, samples: [Float], bits: Int)] = []
        for (index, offset) in [0, 1.0 / 3, 0.5].enumerated() {
            let tone = steadyTone(hertz, rate: rate, offset: offset)
            let seed = UInt64(rate / 1_000) * 10_000 + UInt64(hertz) * 10 + UInt64(index)
            forms.append(("float32 \(index)", tone.map { Float($0) }, 24))
            let pcm = dithered(tone.map { $0 * (0x1p23 - 1) / 0x1p23 }, bits: 24, seed: seed)
            forms.append(("24-bit \(index)", pcm, 24))
            if hertz == 400 || (rate == 48_000 && hertz == 200) {
                let samples = dithered(tone.map { $0 * (0x1p15 - 1) / 0x1p15 }, bits: 16, seed: seed + 5)
                forms.append(("16-bit \(index)", samples, 16))
            }
        }
        if rate == 48_000 && hertz == 100 {
            let sine = (0..<48_000).map { sin(2 * .pi * 100 * Double($0) / 48_000 + 0.1234) }
            let peak = sine.map(abs).max() ?? 1
            let samples = dithered(sine.map { $0 / peak * (0x1p15 - 1) / 0x1p15 }, bits: 16, seed: 480_100)
            forms.append(("16-bit 0.1234 rad", samples, 16))
        }

        var changed: [String] = []
        for form in forms {
            var stage = Self.declip(peak: largest(form.samples), bits: form.bits, rate: rate)
            let kept = render(&stage, [form.samples])[0] == form.samples
            if stage.runs > 0 || !kept { changed.append("\(form.name): \(stage.runs) runs") }
        }
        #expect(changed.isEmpty, "\(hertz) Hz at \(rate): \(changed)")
    }

    /// C4: a run across a block edge gets the fill of one block, to 1e-6: blocks with an edge in the
    /// middle of each of the first 20 filled runs, and blocks of 1 to 600 frames (seed 4). Fail: a
    /// stage that fills each block alone.
    @Test func declipAcrossBlocks() throws {
        let input = clipped(swingVowel(120), over: 2).clipped
        var whole = Self.declip(peak: 1)
        let expected = render(&whole, [input], blocks: [input.count])[0]
        let runs = changedRanges(input, expected)
        try #require(runs.count >= 20)
        let edges: [Int] = runs.prefix(20).map { ($0.lowerBound + $0.upperBound) / 2 }
        let starts: [Int] = [0] + edges
        let split: [Int] = zip(starts, edges).map { $1 - $0 } + [input.count]
        var generator = SeededGenerator(seed: 4)
        let random: [Int] = (0..<200).map { _ in Int.random(in: 1...600, using: &generator) }

        for blocks in [split, random] {
            var stage = Self.declip(peak: 1)
            let output = render(&stage, [input], blocks: blocks)[0]
            let difference = zip(expected, output).map { abs($0 - $1) }.max() ?? 1
            #expect(output.count == input.count && difference <= 1e-6, "blocks \(blocks.prefix(4)): \(difference)")
        }
    }

    /// C4: a flat run over 10 ms stays as it is: a 12.5 Hz sine at 1.5 clipped at full scale (flat
    /// runs of 21.4 ms) keeps each sample, and the clipped vowel after it gets its fills. Fail: a
    /// fill of a 20 ms run.
    @Test func longRunStays() {
        let slow = (0..<9_600).map { Float(min(max(1.5 * sin(2 * .pi * 12.5 * Double($0) / 48_000), -1), 1)) }
        let input = slow + clipped(swingVowel(120, frames: 9_600), over: 2).clipped
        var stage = Self.declip(peak: 1)
        let output = render(&stage, [input])[0]

        let slowKept = output[..<9_600] == input[..<9_600]
        let fills = changedRanges(input, output).count
        #expect(slowKept && fills >= 10, "slow part kept: \(slowKept), \(fills) fills")
    }

    /// C4: the latency is 10 ms of frames plus 4 (445 at 44.1 kHz, 484 at 48 kHz, 964 at 96 kHz).
    /// Each `process` call gives as many frames as it takes, the first 484 frames are zeros,
    /// `finish` gives the last 484, and the stream after the zeros is the clean input. The fills of
    /// a clipped input land only on frames at 99 % of the peak or over. Fail: a delay that differs
    /// from `latency`.
    @Test func declipHoldsItsLatency() {
        let latencies = [44_100.0, 48_000, 96_000].map { Self.declip(peak: 1, rate: $0).latency }
        #expect(latencies == [445, 484, 964])

        let clean = swingVowel(220, frames: 10_000).map { Float(0.5 * $0) }
        var stage = Self.declip(peak: largest(clean))
        var (stream, sizes): ([Float], [Int]) = ([], [])
        for start in stride(from: 0, to: clean.count, by: 3_000) {
            let block = Array(clean[start..<min(start + 3_000, clean.count)])
            let part = stage.process([block])[0]
            sizes.append(part.count - block.count)
            stream += part
        }
        let tail = stage.finish()[0]
        let zeros = stream.prefix(484).allSatisfy { $0 == 0 }
        let delayed = Array((stream + tail).dropFirst(484)) == clean
        #expect(sizes == [0, 0, 0, 0] && tail.count == 484 && zeros && delayed, "\(sizes), \(tail.count)")

        let input = clipped(swingVowel(120), over: 2).clipped
        var filler = Self.declip(peak: 1)
        let fills = changedRanges(input, render(&filler, [input])[0])
        let misplaced = fills.joined().filter { abs(input[$0]) < 0.99 }.count
        #expect(fills.count >= 100 && misplaced == 0, "\(fills.count) fills, \(misplaced) frames under 99 %")
    }

    /// C4: a clipped run with fewer than 5 frames before it in the span, or fewer than 5 after it,
    /// stays as it is, and the stage gives each frame of the span: one span starts 2 frames before a
    /// run and ends 2 frames after a run, the other starts inside a run and ends inside a run. The
    /// runs between them get their fills. Fail: a fill from zero padding.
    @Test func declipLeavesRunsAtTheSpanEdges() throws {
        let vowel = clipped(swingVowel(120), over: 2).clipped
        let runs = Self.clipRuns(vowel).filter { $0.count >= 6 }
        try #require(runs.count >= 10)
        let (first, last) = (runs[2], runs[8])

        for span in [(first.lowerBound - 2)..<(last.upperBound + 2), (first.lowerBound + 1)..<(last.lowerBound + 4)] {
            let input = Array(vowel[span])
            var stage = Self.declip(peak: 1)
            let output = render(&stage, [input])[0]
            let edges = [first, last].map { run in
                let inside = run.clamped(to: span)
                return (inside.lowerBound - span.lowerBound)..<(inside.upperBound - span.lowerBound)
            }
            let kept = edges.allSatisfy { output[$0] == input[$0] }
            let fills = changedRanges(input, output).count
            #expect(output.count == input.count && kept && fills >= 3, "span \(span): kept \(kept), \(fills) fills")
        }
    }
}
