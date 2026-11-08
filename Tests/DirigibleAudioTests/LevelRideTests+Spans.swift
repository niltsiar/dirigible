import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The level ride criteria of the measure spans (C6, C7, C7c, C10), on step arrays with no audio.
extension LevelRideTests {
    /// C6: a run with no block over the gates gives no curve, also when the handles of its clip
    /// have sound.
    @Test func silenceGivesNoCurve() throws {
        let silent = rideSteps([(100, -80)])
        #expect(rideCurve(stepMeanSquares: silent, stepFrames: rideStepFrames, clips: [(0..<480_000, .zero)]) == nil)
        let handles = rideSteps([(100, -20), (100, -80), (100, -20)])
        let clip = (span: 480_000..<960_000, gain: Gain.zero)
        #expect(rideCurve(stepMeanSquares: handles, stepFrames: rideStepFrames, clips: [clip]) == nil)
        let control = (span: 0..<480_000, gain: Gain.zero)
        #expect(rideCurve(stepMeanSquares: handles, stepFrames: rideStepFrames, clips: [control]) != nil)
    }

    /// C6: a non-finite sample empties the steps of the meter, so no gain comes from it.
    @Test func nonFiniteStepsGiveNoCurve() throws {
        var meter = try #require(LoudnessMeter(sampleRate: 48_000, layout: .mono, keepsSteps: true))
        meter.feed(try pcmBuffer([sine(seconds: 2, rate: 48_000).map { $0 * 0.1 }]))
        let clip = (span: 0..<144_000, gain: Gain.zero)
        let before = try #require(meter.stepMeanSquares)
        #expect(rideCurve(stepMeanSquares: before, stepFrames: meter.stepFrames, clips: [clip]) != nil, "control")
        meter.feed(try pcmBuffer([[.nan] + [Float](repeating: 0.1, count: 47_999)]))
        let after = try #require(meter.stepMeanSquares)
        #expect(rideCurve(stepMeanSquares: after, stepFrames: meter.stepFrames, clips: [clip]) == nil)
    }

    /// C6: a clip that starts after the last complete step (a 1-frame clip and a 4799-frame clip
    /// at the end of the file, each in its own measure span) and a clip after a run with no steps
    /// give an empty step range, not a trap.
    @Test func clipsPastTheLastStepDoNotTrap() throws {
        let steps = rideSteps([(200, -20)])
        for tail in [960_001..<960_002, 960_001..<964_800] {
            let clips = [(span: 0..<960_000, gain: Gain.zero), (span: tail, gain: try #require(Gain(dB: -3)))]
            let ride = try #require(rideCurve(stepMeanSquares: steps, stepFrames: rideStepFrames, clips: clips))
            #expect(ride.unmeasured == [1], "tail \(tail)")
        }
        #expect(rideCurve(stepMeanSquares: [], stepFrames: rideStepFrames, clips: [(4_800..<96_000, .zero)]) == nil)
    }

    /// C10: a clip whose measure span has no reference is listed and gets 0 dB; the run still has
    /// a curve from the other clip.
    @Test func unmeasuredClipsAreListed() throws {
        let steps = rideSteps([(100, -26), (100, -80)])
        let ridden = try ride(steps, clips: [(0..<100, 0), (100..<200, -3)])
        #expect(ridden.unmeasured == [1])
        #expect(ridden.dB[100..<200].allSatisfy { $0 == 0 })
        #expect(abs(ridden.dB[50]) <= 0.1, "the measured clip keeps its level")
    }

    /// C4: two clips of one run at -26 and -18 LUFS each keep their own loudness within 0.1 LU,
    /// so the Auto Level gain of each stays right.
    @Test func eachClipKeepsItsLoudness() throws {
        let steps = rideSteps([(100, -26), (20, -80), (100, -18)])
        let clips = [0..<100, 120..<220]
        let gains = try ride(steps, clips: clips.map { ($0, 0) }).dB
        let plain = plainClamp(steps)
        for span in clips {
            let source = try #require(riddenLoudness(steps, nil, span))
            let ridden = try #require(riddenLoudness(steps, gains, span))
            #expect(abs(ridden - source) <= 0.1, "span \(span): \(ridden) LUFS, source \(source) LUFS")
            let shared = try #require(riddenLoudness(steps, plain, span))
            #expect(abs(shared - source) > 1, "control: one reference for the run gives \(shared) LUFS")
        }
    }

    /// C7 (a): handles at -14 LUFS around a clip at -20 LUFS do not move its reference.
    @Test func handlesDoNotMoveTheReference() throws {
        let steps = rideSteps([(100, -14), (100, -20), (100, -14)])
        let gains = try ride(steps, clips: [(100..<200, 0)]).dB
        #expect(abs(gains[150]) <= 0.1, "the clip middle: \(gains[150]) dB, not 0")
        #expect(plainClamp(steps)[150] >= 4, "control: the reference of the run")
    }

    /// C7 (b): a loud region that no clip plays does not move the gain of the clip before it.
    @Test func unplayedAudioDoesNotMoveTheGain() throws {
        let steps = rideSteps([(100, -20), (50, -10), (100, -20)])
        let gains = try ride(steps, clips: [(0..<100, 0), (150..<250, 0)]).dB
        for step in 90..<100 {
            #expect(abs(gains[step] - gains[50]) <= 0.5, "step \(step): \(gains[step]) dB, middle \(gains[50]) dB")
        }
        let plain = plainClamp(steps)
        #expect(abs(plain[99] - plain[50]) > 0.5, "control: a window that reads the region")
    }

    /// C7 (c): the steps outside every measure span take the gain of the nearest span edge step.
    @Test func gapsTakeTheEdgeGain() throws {
        let steps = rideSteps([(10, -40), (45, -26), (45, -18), (50, -10), (45, -18), (45, -26), (20, -40)])
        let gains = try ride(steps, clips: [(10..<100, 0), (150..<240, 0)]).dB
        #expect(gains[99] != gains[150], "control: the two edges differ")
        #expect(gains[0..<10].allSatisfy { $0 == gains[10] })
        #expect(gains[100..<125].allSatisfy { $0 == gains[99] })
        #expect(gains[125..<150].allSatisfy { $0 == gains[150] })
        #expect(gains[240..<260].allSatisfy { $0 == gains[239] })
    }

    /// C7c: a split clip with equal clip gains gives the curve of the clip before the split.
    @Test func splitClipHasNoGainStep() throws {
        let steps = rideSteps([(100, -26), (100, -18)])
        let whole = try #require(
            rideCurve(stepMeanSquares: steps, stepFrames: rideStepFrames, clips: [(0..<960_000, .zero)]))
        let split = try #require(
            rideCurve(
                stepMeanSquares: steps, stepFrames: rideStepFrames,
                clips: [(0..<371_234, .zero), (371_234..<960_000, .zero)]))
        #expect(zip(whole.curve.dB, split.curve.dB).allSatisfy { abs($0 - $1) <= 1e-9 })
        #expect(split.unmeasured.isEmpty)
    }

    /// C7c: a duplicated clip (same span, same gain) gives the curve of one clip.
    @Test func duplicatedClipSharesOneReference() throws {
        let steps = rideSteps([(100, -26), (100, -18)])
        let one = try ride(steps, clips: [(20..<180, 2)])
        let two = try ride(steps, clips: [(20..<180, 2), (20..<180, 2)])
        #expect(zip(one.dB, two.dB).allSatisfy { abs($0 - $1) <= 1e-9 })
        #expect(two.unmeasured.isEmpty)
    }

    /// C7c: two clips at -26 and -18 LUFS with other clip gains that overlap by 0.5 s keep their
    /// loudness, and the gain blends linearly over the shared steps.
    @Test func overlappingClipsWithOtherGainsKeepTheirLoudness() throws {
        let steps = rideSteps([(100, -26), (100, -18)])
        let (first, second) = (0..<103, 98..<200)
        let gains = try ride(steps, clips: [(first, 0), (second, -8)]).dB
        for span in [first, second] {
            let source = try #require(riddenLoudness(steps, nil, span))
            let ridden = try #require(riddenLoudness(steps, gains, span))
            #expect(abs(ridden - source) <= 0.5, "span \(span): \(ridden) LUFS, source \(source) LUFS")
        }
        let alone = (try ride(steps, clips: [(first, 0)]).dB, try ride(steps, clips: [(second, -8)]).dB)
        for step in 98..<103 {
            let weight = (Double(step) + 0.5 - 98) / 5
            let blend = (1 - weight) * alone.0[step] + weight * alone.1[step]
            #expect(abs(gains[step] - blend) <= 1e-9, "step \(step): \(gains[step]) dB, blend \(blend) dB")
        }
        let merged = try ride(steps, clips: [(first, 0), (second, 0)]).dB
        let mergedFirst = try #require(riddenLoudness(steps, merged, first))
        #expect(abs(mergedFirst - (try #require(riddenLoudness(steps, nil, first)))) > 0.5, "control")
    }
}
