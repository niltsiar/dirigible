import Foundation
import Testing

@testable import DirigibleCore

/// The drift fit (decision 0077, D7): the points of an outside recording against its reference.
/// A point is a window center in clip frames and the lag of that window in frames at 48 kHz.
struct DriftFitTests {
    static let rate = 48_000.0
    static let frames = rate / 1000

    /// One point in each 60 s cell, at a seeded place, on `lag = offset + ppm x c` with seeded
    /// Gaussian noise. A point after `pause.minute` gets `pause.seconds` more lag, as a recorder
    /// that paused. Each point is a false match with the chance `falseShare`: a lag anywhere in 60 s
    /// around the offset.
    static func points(
        minutes: Int, ppm: Double, offsetMs: Double, seed: UInt64, noiseMs: Double = 0.05,
        falseShare: Double = 0, pause: (minute: Double, seconds: Double)? = nil
    ) -> [DriftPoint] {
        var random = SplitMix(seed: seed)
        return (0..<minutes).map { cell in
            let c = (60 * Double(cell) + Double.random(in: 5..<55, using: &random)) * rate
            var lag = offsetMs * frames + ppm * 1e-6 * c + noiseMs * frames * gauss(&random)
            if let pause, c > pause.minute * 60 * rate { lag += pause.seconds * rate }
            if Double.random(in: 0..<1, using: &random) < falseShare {
                lag = offsetMs * frames + Double.random(in: -60..<60, using: &random) * rate
            }
            return DriftPoint(clipFrame: c, lag: lag)
        }
    }

    static func gauss(_ random: inout SplitMix) -> Double {
        let u = Double.random(in: Double.ulpOfOne..<1, using: &random)
        let v = Double.random(in: 0..<1, using: &random)
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }

    /// `base` with `ms` more lag at each index.
    static func shifted(_ base: [DriftPoint], _ indexes: [Int], ms: Double) -> [DriftPoint] {
        var out = base
        for k in indexes { out[k].lag += ms * frames }
        return out
    }

    static func fit(_ points: [DriftPoint]) throws(DriftFitFailure) -> DriftFit {
        try DriftFit(points: points, sampleRate: rate)
    }

    static func rateError(_ fit: DriftFit, ppm: Double) -> Double { abs(fit.slope * 1e6 - ppm) }

    /// The error of the offset of a segment, in ms.
    static func offsetError(_ fit: DriftFit, segment: Int = 0, ms: Double) -> Double {
        abs(fit.segments[segment].offset - ms * frames) / frames
    }

    /// The noise of 0.2 ms is a codec copy: a slope from the first and the last point only is over
    /// 0.1 ppm off on some seed, and the fit of all points is not.
    @Test func aCleanLineGivesItsRateAndOffset() throws {
        for noiseMs in [0.05, 0.2] {
            for seed in 0..<20 as Range<UInt64> {
                let points = Self.points(minutes: 60, ppm: 50, offsetMs: 1234.5, seed: seed, noiseMs: noiseMs)
                let fit = try Self.fit(points)
                #expect(fit.segments.count == 1)
                #expect(fit.outliers.isEmpty)
                #expect(Self.rateError(fit, ppm: 50) < 0.1, "seed \(seed), noise \(noiseMs) ms")
                #expect(Self.offsetError(fit, ms: 1234.5) < 0.1, "seed \(seed), noise \(noiseMs) ms")
            }
        }
    }

    @Test func aSlowClockGivesANegativeRate() throws {
        for seed in 0..<20 as Range<UInt64> {
            let fit = try Self.fit(Self.points(minutes: 60, ppm: -135, offsetMs: -800, seed: seed))
            #expect(fit.segments.count == 1)
            #expect(fit.slope < 0)
            #expect(Self.rateError(fit, ppm: -135) < 0.1, "seed \(seed)")
            #expect(Self.offsetError(fit, ms: -800) < 0.1, "seed \(seed)")
        }
    }

    @Test func aPauseStartsASegment() throws {
        for seed in 0..<10 as Range<UInt64> {
            let fit = try Self.fit(
                Self.points(minutes: 60, ppm: 50, offsetMs: 1234.5, seed: seed, pause: (31.3, 20)))
            #expect(fit.segments.count == 2)
            #expect(Self.rateError(fit, ppm: 50) < 0.1, "seed \(seed)")
            #expect(Self.offsetError(fit, segment: 0, ms: 1234.5) < 0.1, "seed \(seed)")
            #expect(Self.offsetError(fit, segment: 1, ms: 1234.5 + 20_000) < 0.1, "seed \(seed)")
            #expect(fit.segments[0].pointRange.upperBound < fit.segments[1].pointRange.lowerBound)
        }
    }

    /// A pause only adds lag. A later segment 30 s under the first would place its piece over the
    /// tail of the piece before it.
    @Test func aLagStepDownGivesNoFit() {
        for seed in 0..<10 as Range<UInt64> {
            #expect(throws: DriftFitFailure.lagStepsBack, "seed \(seed)") {
                try Self.fit(Self.points(minutes: 60, ppm: 50, offsetMs: 1234.5, seed: seed, pause: (31.3, -30)))
            }
        }
    }

    @Test func aStepOf51msSplitsAndOf49msDoesNot() throws {
        for seed in 0..<10 as Range<UInt64> {
            let split = try Self.fit(
                Self.points(minutes: 60, ppm: 50, offsetMs: 1234.5, seed: seed, pause: (31.3, 0.051)))
            #expect(split.segments.count == 2, "seed \(seed)")
            let one = try Self.fit(
                Self.points(minutes: 60, ppm: 50, offsetMs: 1234.5, seed: seed, pause: (31.3, 0.049)))
            #expect(one.segments.count == 1, "seed \(seed)")
            #expect(one.worstResidual / Self.frames > 20, "the step shows in the result")
        }
    }

    @Test func aPauseWithTwoPointsAfterItIsASegment() throws {
        let fit = try Self.fit(
            Self.points(minutes: 60, ppm: 50, offsetMs: 1234.5, seed: 6, pause: (57.6, 20)))
        #expect(fit.segments.count == 2)
        #expect(fit.segments[1].pointRange.count == 2)
        #expect(Self.offsetError(fit, segment: 1, ms: 1234.5 + 20_000) < 0.1)
    }

    @Test func aPauseWithOnePointAfterItGivesNoFit() {
        #expect(throws: DriftFitFailure.endOutlier) {
            try Self.fit(Self.points(minutes: 60, ppm: 50, offsetMs: 1234.5, seed: 6, pause: (58.6, 20)))
        }
    }

    /// `base` with a false match at each index: a lag on the other side of the line, each at least
    /// 1 s from the others, so no two of them make a segment of 2 points.
    static func falseMatches(_ base: [DriftPoint], _ indexes: [Int], offsetMs: Double) -> [DriftPoint] {
        var out = base
        for (j, k) in indexes.enumerated() {
            let side = j % 2 == 0 ? 1.0 : -1.0
            out[k].lag = offsetMs * frames + side * (3 + 2.9 * Double(j)) * rate
        }
        return out
    }

    @Test func aFifthOfFalseMatchesKeepsTheLine() throws {
        let inner = [3, 8, 13, 18, 22, 27, 31, 36, 41, 45, 50, 55]
        for seed in 0..<10 as Range<UInt64> {
            let base = Self.points(minutes: 60, ppm: 50, offsetMs: 1234.5, seed: seed)
            let fit = try Self.fit(Self.falseMatches(base, inner, offsetMs: 1234.5))
            #expect(fit.outliers == inner, "seed \(seed)")
            #expect(Self.rateError(fit, ppm: 50) < 0.1, "seed \(seed)")
            #expect(Self.offsetError(fit, ms: 1234.5) < 0.1, "seed \(seed)")
        }
    }

    @Test func overThirtyPercentOutliersGiveNoFit() {
        let base = Self.points(minutes: 60, ppm: 50, offsetMs: 1234.5, seed: 1)
        let falseMatches = Self.falseMatches(base, Array(stride(from: 2, to: 59, by: 3)), offsetMs: 1234.5)  // 19 of 60
        #expect(throws: DriftFitFailure.tooManyOutliers) { try Self.fit(falseMatches) }
    }

    @Test func twoPointsOneVoicePeriodOffAreOutliers() throws {
        for ms in [5.0, 12.0] {
            let base = Self.points(minutes: 60, ppm: 50, offsetMs: 1234.5, seed: 11)
            let fit = try Self.fit(Self.shifted(base, [20, 21], ms: ms))
            #expect(fit.segments.count == 1)
            #expect(fit.outliers == [20, 21])
            #expect(Self.rateError(fit, ppm: 50) < 0.1)
            #expect(Self.offsetError(fit, ms: 1234.5) < 0.1)
        }
    }

    @Test func anEndPointOffTheLineIsAnOutlier() throws {
        let base = Self.points(minutes: 60, ppm: 50, offsetMs: 1234.5, seed: 11)
        let cases: [(index: Int, ms: Double)] = [
            (0, 5), (0, -5), (0, 12), (0, -12), (59, 5), (59, -5), (59, 12), (59, -12), (59, -300), (0, 300),
        ]
        for (index, ms) in cases {
            let fit = try Self.fit(Self.shifted(base, [index], ms: ms))
            #expect(fit.segments.count == 1, "index \(index), \(ms) ms")
            #expect(fit.outliers == [index], "index \(index), \(ms) ms")
            #expect(Self.rateError(fit, ppm: 50) < 0.1, "index \(index), \(ms) ms")
            #expect(Self.offsetError(fit, ms: 1234.5) < 0.1, "index \(index), \(ms) ms")
            #expect(fit.worstResidual / Self.frames > abs(ms) - 0.5, "the end point shows in the result")
        }
    }

    @Test func anEndJumpOverTheSplitGapGivesNoFit() throws {
        let base = Self.points(minutes: 60, ppm: 50, offsetMs: 1234.5, seed: 11)
        #expect(throws: DriftFitFailure.endOutlier) { try Self.fit(Self.shifted(base, [59], ms: 51)) }
        #expect(throws: DriftFitFailure.endOutlier) { try Self.fit(Self.shifted(base, [0], ms: -51)) }
        #expect(try Self.fit(Self.shifted(base, [59], ms: 49)).outliers == [59])
        #expect(try Self.fit(Self.shifted(base, [0], ms: -49)).outliers == [0])
    }

    @Test func tenPercentFalseMatchesFitMostClips() {
        var noFit = 0
        for seed in 0..<200 as Range<UInt64> {
            let points = Self.points(minutes: 60, ppm: 50, offsetMs: 1234.5, seed: seed, falseShare: 0.1)
            if (try? Self.fit(points)) == nil { noFit += 1 }
        }
        #expect(noFit <= 30, "\(noFit) of 200 clips give no fit")
    }

    @Test func fivePointsFitAndFourDoNot() throws {
        let five = try Self.fit(Self.points(minutes: 5, ppm: 50, offsetMs: 100, seed: 9))
        #expect(five.segments.count == 1)
        #expect(throws: DriftFitFailure.tooFewPoints) {
            try Self.fit(Self.points(minutes: 4, ppm: 50, offsetMs: 100, seed: 9))
        }
    }

    @Test func theRateLimitIs1000ppm() throws {
        let fit = try Self.fit(Self.points(minutes: 60, ppm: 999, offsetMs: 0, seed: 10))
        #expect(Self.rateError(fit, ppm: 999) < 0.1)
        #expect(throws: DriftFitFailure.rateOutOfRange) {
            try Self.fit(Self.points(minutes: 60, ppm: 1001, offsetMs: 0, seed: 10))
        }
    }

    /// At -999.5 ppm the rate is under 1000 ppm, but the ratio 1 / (1 + rate) of the drift link is
    /// 1000.5 ppm from 1.
    @Test func theRateLimitIsTheLimitOfTheLinkRatio() {
        #expect(throws: DriftFitFailure.rateOutOfRange) {
            try Self.fit(Self.points(minutes: 60, ppm: -999.5, offsetMs: 0, seed: 10))
        }
        #expect(throws: Never.self) { try Self.fit(Self.points(minutes: 60, ppm: -998.5, offsetMs: 0, seed: 10)) }
    }

    @Test func theRatioTypeRefusesOutOfRange() {
        #expect(DriftRatio(1 + 999e-6)?.value == 1 + 999e-6)
        #expect(DriftRatio(1 - 999e-6)?.value == 1 - 999e-6)
        #expect(DriftRatio(1 + 1000e-6) == nil)
        #expect(DriftRatio(1 - 1000e-6) == nil)
        #expect(DriftRatio(.nan) == nil)
        #expect(DriftRatio(.infinity) == nil)
    }

    @Test func alternatingLinesGiveNoFit() {
        let alternating = Self.points(minutes: 60, ppm: 50, offsetMs: 1234.5, seed: 13).enumerated().map {
            DriftPoint(clipFrame: $1.clipFrame, lag: $1.lag + ($0 / 5 % 2 == 1 ? 300 * Self.frames : 0))
        }
        #expect(throws: DriftFitFailure.twoLines) { try Self.fit(alternating) }
    }
}
