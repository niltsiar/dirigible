import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The frames of a 100 ms step at 48 kHz.
let rideStepFrames = 4_800

/// The step mean squares of `parts`: each part has its length in steps and its loudness in LUFS.
func rideSteps(_ parts: [(steps: Int, lufs: Double)]) -> [Double] {
    parts.flatMap { Array(repeating: Loudness.meanSquare($0.lufs), count: $0.steps) }
}

/// The ride curve of one measure group that holds all of `steps`.
func ride(_ steps: [Double]) throws -> [Double] {
    try #require(LevelRide.standard.gains(steps)).dB
}

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

/// The gated integrated loudness (BS.1770-5) of `steps` after `gains`: blocks of 4 steps, one at
/// each step.
func riddenLoudness(_ steps: [Double], _ gains: [Double]? = nil, _ range: Range<Int>? = nil) -> Double? {
    let range = range ?? steps.indices
    let ridden = range.map { steps[$0] * pow(10, (gains?[$0] ?? 0) / 10) }
    let blocks = ridden.count < 4 ? [] : (3..<ridden.count).map { ridden[$0 - 3...$0].reduce(0, +) / 4 }
    return Loudness(blocks: blocks).integrated?.value
}

/// The power mean in LUFS of `steps` after `gains`, over `range`.
func windowLoudness(_ steps: [Double], _ gains: [Double], _ range: Range<Int>) -> Double {
    Loudness.lufs(range.map { steps[$0] * pow(10, gains[$0] / 10) }.reduce(0, +) / Double(range.count))
}

/// The negative control: one reference for all steps, a window that reads every step (also a
/// pause), and no smoothing.
func plainClamp(_ steps: [Double]) -> [Double] {
    let reference = riddenLoudness(steps)!
    return steps.indices.map { step in
        let window = max(0, step - 5)...min(steps.count - 1, step + 5)
        let mean = steps[window].reduce(0, +) / Double(window.count)
        return min(max(reference - Loudness.lufs(mean), -6), 6)
    }
}

/// The steps of 10 s of words at -23 LUFS with 0.4 s gaps at -50 LUFS: each word lasts `word`
/// seconds and the first starts `lead` seconds after the run start, so the steps that a word edge
/// cuts mix the two levels.
func words(_ word: Double, lead: Double) -> [Double] {
    let (loud, floor) = (Loudness.meanSquare(-23), Loudness.meanSquare(-50))
    return (0..<100).map { step in
        let (start, end) = (Double(step) / 10, Double(step + 1) / 10)
        var covered = 0.0
        var onset = lead
        while onset < end {
            covered += max(0, min(end, onset + word) - max(start, onset))
            onset += word + 0.4
        }
        let part = covered * 10
        return part * loud + (1 - part) * floor
    }
}

/// The level ride criteria of run 2026-10-14-leveler (C1 to C5b), on step arrays with no audio.
struct LevelRideTests {
    let c1 = rideSteps([(100, -26), (100, -18)])
    let c3 = rideSteps([(100, -20), (40, -23), (40, -50), (100, -20)])

    /// C3: the floor between quiet speech and loud speech holds the gain of the quiet speech
    /// (+2.56 dB on paper), not the clamp of a window that reads the floor. From step 168, the
    /// smoothing reads the lower gain of the loud speech after the floor.
    @Test func pausesHoldTheGain() throws {
        let gains = try ride(c3)
        #expect(gains[140..<180].allSatisfy { $0 <= 2.66 }, "no floor step over +2.56")
        for step in 148..<168 {
            #expect(abs(gains[step] - 2.56) <= 0.1, "floor step \(step): \(gains[step]) dB, not +2.56")
        }
        #expect(abs(gains[139] - 2.56) <= 0.1, "the last quiet speech step: \(gains[139]) dB, not +2.56")
        #expect(plainClamp(c3)[160] >= 5.9, "control: the plain clamp gives the floor +6 dB")
    }

    /// C1: 10 s at -26 LUFS and 10 s at -18 LUFS come within 1 LU (8 LU with no ride).
    @Test func evensTwoLevels() throws {
        let gains = try ride(c1)
        let quiet = windowLoudness(c1, gains, 20..<80)
        let loud = windowLoudness(c1, gains, 120..<180)
        #expect(abs(loud - quiet) <= 1, "the middles differ by \(loud - quiet) LU")
        let flat = [Double](repeating: 0, count: c1.count)
        #expect(windowLoudness(c1, flat, 120..<180) - windowLoudness(c1, flat, 20..<80) >= 7.9)
    }

    /// C2: a 5 s passage about 9 LU under the reference gets +6 dB, and one about 9 LU over -6 dB.
    @Test func boostAndCutStopAtSixDecibels() throws {
        let under = rideSteps([(450, -20), (50, -29), (450, -20)])
        #expect(try #require(riddenLoudness(under)) + 29 >= 8.5, "the passage is about 9 LU under")
        #expect(abs(try ride(under)[475] - 6) <= 0.1)
        let over = rideSteps([(450, -20), (50, -9), (450, -20)])
        #expect(-9 - (try #require(riddenLoudness(over))) >= 8.5, "the passage is about 9 LU over")
        #expect(abs(try ride(over)[475] + 6) <= 0.1)
    }

    /// C3: a passage 14 LU under the reference rides as speech (+6 dB, the clamp); one 16 LU
    /// under is a pause and holds the gain of the speech before it.
    @Test func gateDepthIsFifteen() throws {
        let steps = rideSteps([(100, -20), (30, -34), (100, -20), (30, -36), (100, -20)])
        #expect(abs(try #require(riddenLoudness(steps)) + 20) <= 0.1, "the reference is -20 LUFS")
        let gains = try ride(steps)
        #expect(abs(gains[115] - 6) <= 0.1, "14 LU under: \(gains[115]) dB, not +6")
        #expect(abs(gains[245] - gains[225]) <= 0.1, "16 LU under: \(gains[245]) dB, not \(gains[225])")
    }

    /// C3b: no pause step gets more than the raw gain of the speech step before it (the paper
    /// value of each case) plus 0.5 dB.
    @Test(arguments: [
        // (a) The C3 fixture: the floor holds +2.56.
        (rideSteps([(100, -20), (40, -23), (40, -50), (100, -20)]), 2.56, 160, 2.56),
        // (b) Words with a 3 s floor in their middle: words and floor 0 dB after the offset.
        (wordsWithFloor(), 0, 64, 0),
        // (c) A decay tail of -30 and -34 LUFS before the floor: the floor holds the raw gain of
        // the -34 step, +3.61 with the window of 15 steps.
        (rideSteps([(100, -20), (40, -23), (1, -30), (1, -34), (40, -50), (100, -20)]), 3.61, 162, 3.61),
        // (d) Loud, pause, quiet: the pause holds the loud gain -2.37, with the offset of about
        // +0.08 -2.29, not the gain of the quiet phrase.
        (rideSteps([(50, -18), (20, -50), (50, -26)]), -2.37, 60, -2.29),
    ])
    func noFloorStepGetsMoreThanTheSpeechBeforeIt(
        steps: [Double], speechBefore: Double, floorStep: Int, floorGain: Double
    ) throws {
        let gains = try ride(steps)
        let gate = Loudness.meanSquare(try #require(riddenLoudness(steps)) - 15)
        let highest = steps.indices.filter { steps[$0] < gate }.map { gains[$0] }.max() ?? -.infinity
        #expect(highest <= speechBefore + 0.5, "a pause step gets \(highest) dB, over \(speechBefore) + 0.5")
        #expect(abs(gains[floorStep] - floorGain) <= 0.1, "step \(floorStep): \(gains[floorStep]) dB, not \(floorGain)")
    }

    /// C3b case (d): the pause holds the loud gain, the quiet phrase gets 8 dB more, and the
    /// smoothing ramps up from the first quiet step, (5 x loud + 6 x quiet) / 11, to the quiet
    /// gain 0.5 s after the onset.
    @Test func quietPhraseAfterAPauseRampsUp() throws {
        let gains = try ride(rideSteps([(50, -18), (20, -50), (50, -26)]))
        let (loud, quiet) = (gains[25], gains[95])
        #expect(abs(gains[60] - loud) <= 0.1, "pause \(gains[60]) dB, loud \(loud) dB")
        #expect(abs(quiet - loud - 8) <= 0.1, "quiet \(quiet) dB, loud \(loud) dB")
        #expect(abs(gains[70] - (5 * loud + 6 * quiet) / 11) <= 0.01, "the first quiet step: \(gains[70]) dB")
        #expect(abs(gains[75] - quiet) <= 0.01, "0.5 s after the onset: \(gains[75]) dB")
    }

    /// C4 and the texts of the command: when the 6 dB limit stops the gain after the offset, the
    /// integrated loudness changes, so no text says that it always stays the same.
    @Test func limitStopsTheLoudnessOffset() throws {
        let steps = rideSteps([(300, -20), (300, -32)])
        let gains = try ride(steps)
        #expect(gains.max() == LevelRide.standard.maxBoost, "the limit stops the gain")
        let (ridden, source) = (try #require(riddenLoudness(steps, gains)), try #require(riddenLoudness(steps)))
        #expect(abs(ridden - source) > 0.1, "ridden \(ridden) LUFS, source \(source) LUFS")
    }

    /// C4: the ride keeps the gated integrated loudness of the clip within 0.1 LU.
    @Test func keepsTheIntegratedLoudness() throws {
        for steps in [c1, c3] {
            let reference = try #require(riddenLoudness(steps))
            let ridden = try #require(riddenLoudness(steps, try ride(steps)))
            #expect(abs(ridden - reference) <= 0.1, "ridden \(ridden) LUFS, source \(reference) LUFS")
        }
    }

    /// C4: words with gaps keep their loudness through the offset: 0 dB at each step, not -3 dB.
    @Test func gappySpeechKeepsItsLoudness() throws {
        let steps = words(0.3, lead: 0)
        let gains = try ride(steps)
        #expect(gains.allSatisfy { abs($0) <= 0.1 }, "gains from \(gains.min()!) to \(gains.max()!) dB, not 0")
        let reference = try #require(riddenLoudness(steps))
        #expect(abs(try #require(riddenLoudness(steps, gains)) - reference) <= 0.1)
    }

    /// C4: a 4 s passage 12 LU under, under the relative gate, gets the clamp +6 dB; the offset
    /// lifts the loud speech over 0 dB, so the span keeps its loudness.
    @Test func quietPassageUnderTheGateKeepsTheSpanLoudness() throws {
        let steps = rideSteps([(100, -20), (40, -32), (100, -20)])
        let gains = try ride(steps)
        #expect(gains[50] >= 0.3, "loud: \(gains[50]) dB, about 0 with no offset")
        #expect(abs(gains[120] - 6) <= 0.1, "passage: \(gains[120]) dB, not +6")
        let reference = try #require(riddenLoudness(steps))
        #expect(abs(try #require(riddenLoudness(steps, gains)) - reference) <= 0.1)
    }

    /// C5: the gain changes by 1.5 dB or less between two steps, also at the 8 LU jump of C1.
    @Test func gainMovesSmoothly() throws {
        let gains = try ride(c1)
        let largest = zip(gains, gains.dropFirst()).map { abs($1 - $0) }.max()!
        #expect(largest <= 1.5, "a change of \(largest) dB")
        let plain = plainClamp(c1)
        #expect(zip(plain, plain.dropFirst()).map { abs($1 - $0) }.max()! > 1.5, "control")
    }

    /// C5b: words with gaps do not pump: on the step grid, 37 ms off it, and 0.33 s words 37 ms off.
    /// The off-grid limit is the largest measured value, 0.37 dB, rounded up.
    @Test(arguments: [(0.3, 0.0, 0.01), (0.3, 0.037, 0.4), (0.33, 0.037, 0.4)])
    func burstySpeechDoesNotPump(word: Double, lead: Double, limit: Double) throws {
        let steps = words(word, lead: lead)
        let gains = try ride(steps)
        let variation = gains.max()! - gains.min()!
        #expect(variation <= limit, "the gain moves by \(variation) dB")
        let plain = plainClamp(steps)
        #expect(plain.max()! - plain.min()! > 1, "control")
    }
}

/// C3b case (b): the words of C5b, then a 3 s floor at -50 LUFS, then the words again.
func wordsWithFloor() -> [Double] {
    let speech = words(0.3, lead: 0)
    return Array(speech[0..<49]) + rideSteps([(30, -50)]) + Array(speech[0..<49])
}
