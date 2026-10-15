import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Run export-loudness: `LoudnessSearch` decides each step of an export with a loudness target.
/// These tests give it measurements and read the steps, so they need no audio file.
struct LoudnessSearchTests {
    typealias Step = LoudnessSearch.Step

    /// A file with no margin and no offset, and a read-back.
    static let plain = LoudnessSearch.Start(margin: 0, offset: 0, readsBack: true)

    /// A mix at -30 LUFS with a true peak of -20 dBTP: the gain is +14 dB and the limiter does
    /// nothing.
    static func quiet(_ start: LoudnessSearch.Start = plain, limits: LoudnessSearch.Limits = .init()) -> (
        LoudnessSearch, Step
    ) {
        var search = LoudnessSearch(target: -16, start: start, limits: limits)
        let step = search.next(after: .mix(loudness: -30, truePeak: -20))
        return (search, step)
    }

    /// The steps that `search` gives while `response` answers each trial and write with the
    /// limited loudness for a gain and a ceiling, and `readBack` answers each read-back with the
    /// decoded loudness and true peak, given the loudness of the file that was written.
    static func run(
        _ search: inout LoudnessSearch, first: Step, response: (Double, Double) -> Double?,
        readBack: (Double?) -> (Double?, Double?)
    ) -> [Step] {
        var steps = [first]
        var limited: Double?
        while let step = steps.last, step != .done, steps.count < 100 {
            switch step {
            case .trial(let gain, let ceiling):
                steps.append(search.next(after: .trial(output: response(gain, ceiling))))
            case .write(let gain, let ceiling):
                limited = response(gain, ceiling)
                steps.append(search.next(after: .written(output: limited)))
            case .readBack:
                let (loudness, truePeak) = readBack(limited)
                steps.append(search.next(after: .readBack(loudness: loudness, truePeak: truePeak)))
            case .done: break
            }
        }
        return steps
    }

    static func isWrite(_ step: Step, gain: Double, ceiling: Double) -> Bool {
        guard case .write(let g, let c) = step else { return false }
        return abs(g - gain) <= 1e-9 && abs(c - ceiling) <= 1e-9
    }

    static func gains(_ steps: [Step], trials: Bool) -> [Double] {
        steps.compactMap {
            switch $0 {
            case .trial(let gain, _): trials ? gain : nil
            case .write(let gain, _): trials ? nil : gain
            case .readBack, .done: nil
            }
        }
    }

    /// A response that saturates under -16.8 LUFS and rises with the gain, and read-backs that
    /// stay over -1.0 dBTP: each round runs 4 trial steps and one write, for 3 rounds. The write
    /// gain of a round is the trial gain with the smallest miss.
    @Test func theCapsStopTheSearchAndKeepTheLastFile() {
        var search = LoudnessSearch(target: -16, start: Self.plain)
        let first = search.next(after: .mix(loudness: -15.5, truePeak: 0.85))
        func response(_ gain: Double, _ ceiling: Double) -> Double? { -17 + 0.2 * atan(gain) / (.pi / 2) }

        let steps = Self.run(&search, first: first, response: response) { ($0, -0.5) }

        let trials = steps.filter { if case .trial = $0 { true } else { false } }
        let writes = steps.filter { if case .write = $0 { true } else { false } }
        #expect(trials.count == 12, "\(trials.count) trial steps, not 12")
        #expect(writes.count == 3, "\(writes.count) writes, not 3")
        #expect(steps.last == .done)
        #expect((search.trials, search.writes, search.readBacks) == (12, 3, 3))
        var round: [Step] = []
        for step in steps {
            switch step {
            case .trial: round.append(step)
            case .write(let gain, _):
                #expect(round.count == 4, "a round of \(round.count) trial steps")
                let misses = round.map { step -> (Double, Double) in
                    guard case .trial(let g, let c) = step else { return (0, 0) }
                    return (g, abs((response(g, c) ?? 0) + 16))
                }
                let best = misses.min { $0.1 < $1.1 }?.0
                #expect(gain == best, "the write gain \(gain) is not the smallest miss \(String(describing: best))")
                round = []
            case .readBack, .done: break
            }
        }
    }

    /// A decoded true peak of -0.5 dBTP lowers the ceiling by 0.6 dB (-0.5 - (-1.0) + 0.1). A
    /// decoded true peak of -1.0 dBTP or under keeps it.
    @Test func aTruePeakExcessLowersTheCeiling() {
        var (search, first) = Self.quiet()
        #expect(first == .write(gain: 14, ceiling: -1))
        #expect(search.next(after: .written(output: -16)) == .readBack)

        let retry = search.next(after: .readBack(loudness: -16, truePeak: -0.5))

        #expect(abs(search.ceiling - -1.6) <= 1e-9, "the ceiling: \(search.ceiling)")
        #expect(retry == .write(gain: 14, ceiling: search.ceiling))
        #expect(search.next(after: .written(output: -16)) == .readBack)
        #expect(search.next(after: .readBack(loudness: -16, truePeak: -1.0)) == .done)
        #expect(abs(search.ceiling - -1.6) <= 1e-9, "the ceiling moved at -1.0 dBTP: \(search.ceiling)")
    }

    /// A decoded loudness 0.3 LU under the target, with a true peak under the ceiling, keeps the
    /// ceiling and moves the effective target by 0.3 LU. A miss of 0.15 LU ends the search. After
    /// a round that the trial cap stopped, a loudness miss also ends the search.
    @Test func aLoudnessOnlyMissMovesOnlyTheTarget() {
        var (search, _) = Self.quiet()
        _ = search.next(after: .written(output: -16))

        let retry = search.next(after: .readBack(loudness: -16.3, truePeak: -1.1))

        #expect(search.ceiling == -1, "the ceiling: \(search.ceiling)")
        #expect(abs(search.effectiveTarget - -15.7) <= 1e-9, "the effective target: \(search.effectiveTarget)")
        #expect(retry == .write(gain: search.effectiveTarget + 30, ceiling: -1))
        _ = search.next(after: .written(output: -15.7))
        #expect(search.next(after: .readBack(loudness: -16.15, truePeak: -1.1)) == .done)

        var capped = LoudnessSearch(target: -16, start: Self.plain, limits: .init(trialPasses: 1))
        _ = capped.next(after: .mix(loudness: -15.5, truePeak: 0.85))
        #expect(capped.next(after: .trial(output: -17)) == .write(gain: -0.5, ceiling: -1))
        #expect(capped.next(after: .written(output: -17)) == .readBack)
        #expect(capped.next(after: .readBack(loudness: -17, truePeak: -1.5)) == .done)
    }

    /// The MP3 start offset of 0.45 dB aims the limited signal at -15.55 LUFS. A read-back that
    /// measures a codec change of 0.44 LU replaces the offset: the effective target is the target
    /// plus 0.44, not plus 0.89.
    @Test func theCodecOffsetCountsOnce() {
        var (search, first) = Self.quiet(.init(margin: 0.5, offset: 0.45, readsBack: true))
        #expect(Self.isWrite(first, gain: 14.45, ceiling: -1.5), "\(first)")
        #expect(abs(search.effectiveTarget - -15.55) <= 1e-9)
        _ = search.next(after: .written(output: -15.55))

        _ = search.next(after: .readBack(loudness: -15.99, truePeak: -3))

        #expect(abs(search.effectiveTarget - -15.56) <= 1e-9, "the effective target: \(search.effectiveTarget)")
    }

    /// With the ceiling at -1 dBTP the limiter changes no frame when the true peak plus the gain
    /// is at or under -1.05 dBTP (the ceiling minus `TruePeakLimiter.margin`). A mix at -30 LUFS
    /// gets +14 dB.
    @Test func aMixUnderTheCeilingWritesAtOnce() {
        var under = LoudnessSearch(target: -16, start: Self.plain)
        var over = LoudnessSearch(target: -16, start: Self.plain)

        let write = under.next(after: .mix(loudness: -30, truePeak: -15.08))
        let trial = over.next(after: .mix(loudness: -30, truePeak: -15.02))

        #expect(write == .write(gain: 14, ceiling: -1), "0.03 dB under the limit gave \(write)")
        #expect(trial == .trial(gain: 14, ceiling: -1), "0.03 dB over the limit gave \(trial)")
    }

    /// No measurement gives a gain of 0 dB, no trial step, and no loudness retry. The true-peak
    /// retry still runs, and a nil true peak counts as under the ceiling.
    @Test func aNilMeasurementMakesNoGain() {
        var search = LoudnessSearch(target: -16, start: Self.plain)
        #expect(search.next(after: .mix(loudness: nil, truePeak: 0.85)) == .write(gain: 0, ceiling: -1))
        #expect(search.next(after: .written(output: nil)) == .readBack)
        #expect(search.next(after: .readBack(loudness: nil, truePeak: nil)) == .done)

        var retry = LoudnessSearch(target: -16, start: Self.plain)
        _ = retry.next(after: .mix(loudness: nil, truePeak: -3))
        _ = retry.next(after: .written(output: nil))
        let step = retry.next(after: .readBack(loudness: -40, truePeak: -0.5))
        #expect(step == .write(gain: 0, ceiling: retry.ceiling))
        #expect(retry.trials == 0 && retry.writes == 2, "\(retry.trials) trials, \(retry.writes) writes")
    }

    /// The "train" points of probe P5 (gain, limited loudness): the first trial at
    /// `target - measured`, a gain step, then the secant reach -16 LUFS within 0.1 LU in 4 trial
    /// steps.
    @Test func aGainStepThenTheSecantReachTheTarget() {
        let points = [(-0.326, -17.066), (0.741, -16.655), (2.174, -16.010), (2.437, -15.880)]
        func response(_ gain: Double, _ ceiling: Double) -> Double? {
            let upper = points.firstIndex { $0.0 >= gain } ?? points.count - 1
            let (a, b) = upper == 0 ? (points[0], points[1]) : (points[upper - 1], points[upper])
            return a.1 + (b.1 - a.1) * (gain - a.0) / (b.0 - a.0)
        }
        var search = LoudnessSearch(target: -16, start: .init(margin: 0, offset: 0, readsBack: false))
        let first = search.next(after: .mix(loudness: -15.674, truePeak: 0.85))

        let steps = Self.run(&search, first: first, response: response) { _ in (nil, nil) }

        let trials = Self.gains(steps, trials: true)
        let written = Self.gains(steps, trials: false)
        #expect(trials.count == 4, "\(trials.count) trial steps: \(trials)")
        let expected = [-0.326, 0.741, 2.437, 2.174]
        #expect(zip(trials, expected).allSatisfy { abs($0 - $1) <= 0.01 }, "the trial gains: \(trials)")
        let output = written.first.flatMap { response($0, -1) } ?? .nan
        #expect(abs(output - -16) <= 0.1, "the written file reads \(output) LUFS")
        #expect(steps.last == .done && written.count == 1)
    }
}
