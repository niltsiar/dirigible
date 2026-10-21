import Foundation
import Testing

@testable import DirigibleCore

/// An envelope from (file frame, dB) pairs, which are valid.
func envelope(_ pairs: [(Int, Double)]) -> GainEnvelope {
    GainEnvelope(pairs.map { GainEnvelope.Point(frame: Frames($0.0), gain: Gain(dB: $0.1)!) })!
}

/// The gain envelope value (decision 0060, C1).
struct GainEnvelopeTests {
    /// C1: linear in dB between two points, held before the first and after the last. Worked
    /// values, then a seeded oracle: a linear scan over the points with the formula of 0060.
    /// Control: a linear-amplitude curve gives -4.74 dB at frame 24 000.
    @Test func theGainIsLinearInDecibelsAndHoldsOutside() throws {
        let ramp = envelope([(0, 0), (48_000, -16)])
        #expect(abs(ramp.gain(at: 24_000) - -8) < 1e-12, "the middle is -8 dB: \(ramp.gain(at: 24_000))")
        #expect(abs(pow(10, ramp.gain(at: 24_000) / 20) - 0.398107) < 1e-6, "factor 0.398107")
        #expect(ramp.gain(at: 60_000) == -16, "held after the last point")
        let late = envelope([(1_000, -3), (2_000, -9)])
        #expect(late.gain(at: 0) == -3 && late.gain(at: 1_000) == -3 && late.gain(at: 2_000) == -9)
        #expect(GainEnvelope.empty.gain(at: 500) == 0)

        var random = SplitMix(seed: 7)
        var wrong = 0
        for _ in 0..<2_000 {
            let frames = Set(
                (0..<Int.random(in: 1...6, using: &random)).map { _ in
                    Int.random(in: 0...100_000, using: &random)
                }
            ).sorted()
            let pairs = frames.map { ($0, Double.random(in: -40...12, using: &random)) }
            let tested = envelope(pairs)
            let frame = Int.random(in: -1_000...101_000, using: &random)
            let expected: Double
            if frame <= pairs[0].0 {
                expected = pairs[0].1
            } else if frame >= pairs[pairs.count - 1].0 {
                expected = pairs[pairs.count - 1].1
            } else {
                let right = pairs.firstIndex { $0.0 > frame }!
                let ((f0, g0), (f1, g1)) = (pairs[right - 1], pairs[right])
                expected = g0 + (g1 - g0) * Double(frame - f0) / Double(f1 - f0)
            }
            if abs(tested.gain(at: Frames(frame)) - expected) > 1e-9 { wrong += 1 }
        }
        #expect(wrong == 0, "\(wrong) of 2000 seeded values differ from the formula")
    }

    /// A point with no gain has the envelope value, so no sample changes; a point there gives nil.
    /// A given gain sets the point, and the same gain there gives nil. Seeded random envelopes.
    @Test func aPointWithNoGainChangesNoSample() throws {
        var random = SplitMix(seed: 11)
        for _ in 0..<2_000 {
            let frames = Set(
                (0..<Int.random(in: 0...6, using: &random)).map { _ in Int.random(in: 0...100_000, using: &random) }
            ).sorted()
            let before = envelope(frames.map { ($0, Double.random(in: -60...20, using: &random)) })
            let frame = Frames(Int.random(in: 0...100_000, using: &random))
            guard let after = before.withPoint(at: frame) else {
                #expect(before.points.contains { $0.frame == frame }, "nil only with a point there")
                continue
            }
            #expect(after.points.count == before.points.count + 1 && after.points.contains { $0.frame == frame })
            let probes = [0, 100_000, frame.count - 1, frame.count, frame.count + 1] + frames
            #expect(
                probes.allSatisfy { abs(after.gain(at: Frames($0)) - before.gain(at: Frames($0))) < 1e-9 },
                "the point at \(frame) changed a sample of \(before)")
        }

        let ramp = envelope([(0, 0), (48_000, -16)])
        let set = try #require(ramp.withPoint(at: 24_000, gain: Gain(dB: -3)!))
        #expect(set.points.map(\.gain.dB) == [0, -3, -16], "a given gain replaces the envelope value")
        #expect(set.withPoint(at: 24_000, gain: Gain(dB: -3)!) == nil, "the same gain there is no change")
        #expect(set.withPoint(at: 24_000) == nil, "a point there and no gain: no change")
    }

    /// The initializer refuses a negative frame and frames that do not ascend strictly.
    @Test func theInitializerRefusesFramesOutOfOrder() {
        func point(_ frame: Int) -> GainEnvelope.Point { GainEnvelope.Point(frame: Frames(frame), gain: .zero) }
        #expect(GainEnvelope([point(0), point(10)]) != nil, "the control is valid")
        #expect(GainEnvelope([point(-1), point(10)]) == nil, "a negative frame")
        #expect(GainEnvelope([point(10), point(10)]) == nil, "two points on one frame")
        #expect(GainEnvelope([point(10), point(5)]) == nil, "descending frames")
    }

    /// The edge rule of range gain and duck (plan gate 2 item 1): no corner outside the file keeps
    /// the corners; a dropped corner before 0 or after the file length gives one point at that
    /// edge, with the value of the function there; an edge that has a point gets no second one.
    @Test func theEdgeRuleKeepsOnePointAtEachFileEdge() {
        func fitted(_ corners: [(frame: Int, dB: Double)]) -> GainEnvelope {
            GainEnvelope.fitted(corners, fileLength: 6_000)
        }
        #expect(fitted([(1_000, -10), (5_000, -10)]) == envelope([(1_000, -10), (5_000, -10)]), "nothing dropped")
        #expect(
            fitted([(-1_000, 0), (1_000, -10), (5_000, -10), (7_000, 0)])
                == envelope([(0, -5), (1_000, -10), (5_000, -10), (6_000, -5)]), "a corner past each edge")
        #expect(fitted([(0, -2), (6_000, -4), (8_000, 0)]) == envelope([(0, -2), (6_000, -4)]), "a point at the end")
        #expect(fitted([(-3_000, -6), (-1_000, -6)]) == envelope([(0, -6)]), "every corner before the file")
        #expect(fitted([(-10, 200), (10, 0)]) == envelope([(0, 96), (10, 0)]), "a gain clamps to the range")
    }
}
