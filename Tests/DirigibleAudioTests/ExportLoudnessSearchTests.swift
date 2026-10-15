import AVFoundation
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

/// Run export-loudness: `exportMix` with a loudness target reaches the target after the limiter.
struct SearchedExportTests {
    /// "train": a 20 s 1 kHz carrier at -20 dBFS with a 2 ms fs/4 burst at 45 degrees and 1.0 FFS
    /// every 250 ms from 0.5 s, the same in both channels. The limiter takes 1.07 LU of its loudness
    /// when one gain reaches the target (probe P5).
    static func train(seconds: Int = 20, rate: Int = 48_000) -> [[Float]] {
        var samples = tone([(Double(seconds), -20)], rate: rate)[0]
        let length = rate * 2 / 1000
        for start in stride(from: rate / 2, to: samples.count - length, by: rate / 4) {
            for index in 0..<length { samples[start + index] += Float(sin(.pi / 2 * Double(index) + .pi / 4)) }
        }
        return [samples, samples]
    }

    /// What an export gave: the files, and the steps of the search.
    struct Run {
        var url: URL
        var result: ExportResult
        /// Keeps the folder of the files until the test ends.
        var package: MixPackage
        var steps: [LoudnessSearch.Step]
        var packageCalls: Int

        var trials: Int { steps.filter { if case .trial = $0 { true } else { false } }.count }
        var writes: Int { steps.filter { if case .write = $0 { true } else { false } }.count }
        var readBacks: Int { steps.filter { $0 == .readBack }.count }
    }

    /// Exports all of `channels` with the target. `isCancelled` and `progress` are the hooks of the
    /// export, and `tuning` sets the caps and the start margin.
    static func export(
        _ channels: [[Float]], _ options: ExportOptions, to name: String = "mix.wav",
        tuning: ExportTuning = .init(), chunk: Int = 48_000, progress: (Double) -> Void = { _ in },
        isCancelled: () -> Bool = { false }
    ) throws -> Run {
        let package = try ExportTests.package(channels)
        let url = package.folder.url.appending(path: name)
        let source = try #require(ExportSource(range: 0..<Frames(channels[0].count)))
        var (steps, calls) = ([LoudnessSearch.Step](), 0)
        var tuning = tuning
        let observe = tuning.onStep
        tuning.onStep = {
            steps.append($0)
            observe?($0)
        }
        let result = try exportMix(
            package.session, source: source, options: options, to: url,
            package: {
                calls += 1
                return package.url
            }, progress: progress, isCancelled: isCancelled, chunk: chunk, tuning: tuning)
        return Run(url: url, result: result, package: package, steps: steps, packageCalls: calls)
    }

    @Test(arguments: [(ChannelLayout.stereo, -16.0), (.mono, -19.0)])
    func aPeakyMixReachesTheTargetAfterTheLimiter(layout: ChannelLayout, target: Double) throws {
        let export = try Self.export(Self.train(), ExportLoudnessTests.options(.podcast, layout))

        let back = try ExportTests.read(export.url).channels
        expectLUFS(try measure(back).integrated, target, "the read-back")
        let peak = try #require(try truePeak(back))
        #expect(peak <= -1.0, "the read-back true peak: \(peak) dBTP")
        let report = try #require(export.result.loudness)
        expectLUFS(report.output, target, tolerance: 0.05, "the report output")
        #expect(
            abs((report.truePeak ?? .nan) - peak) <= 0.05,
            "the report true peak: \(String(describing: report.truePeak))")
    }

    /// A mix under the ceiling gets the gain at once: pass 1 and the write read the package 20 times
    /// each, with no trial pass.
    @Test func aMixUnderTheCeilingRendersTwice() throws {
        let export = try Self.export(tone([(20, -30)]), ExportLoudnessTests.options(.podcast))

        #expect(export.packageCalls == 40, "\(export.packageCalls) package reads, not 40")
        #expect(export.trials == 0 && export.writes == 1, "\(export.steps)")
    }

    /// The cancel at the 25th check is in the first trial pass (pass 1 has 20 checks).
    @Test func aCancelInATrialPassLeavesNothing() throws {
        var (checks, steps) = (0, [LoudnessSearch.Step]())
        let package = try ExportTests.package(Self.train())
        let source = try #require(ExportSource(range: 0..<960_000))
        var tuning = ExportTuning()
        tuning.onStep = { steps.append($0) }

        #expect(throws: ExportError.cancelled) {
            try exportMix(
                package.session, source: source, options: ExportLoudnessTests.options(.podcast),
                to: package.folder.url.appending(path: "mix.wav"), package: { package.url },
                isCancelled: {
                    checks += 1
                    return checks == 25
                }, tuning: tuning)
        }

        let trial = steps.contains { if case .trial = $0 { true } else { false } }
        #expect(trial && steps.count == 1, "the cancel was not in a trial pass: \(steps)")
        try MP3ExportTests.expectNoOutput(package)
    }

    /// The trial passes share 0.15...0.3, the write follows, and the last value is 1.
    @Test func progressNeverGoesDownAcrossTrialPasses() throws {
        var values: [Double] = []

        let export = try Self.export(Self.train(), ExportLoudnessTests.options(.podcast), chunk: 4_800) {
            values.append($0)
        }

        #expect(export.trials >= 3, "\(export.trials) trial passes")
        #expect(values.count <= 101, "\(values.count) calls")
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 }, "the values go down")
        #expect(values.last == 1, "the last value: \(String(describing: values.last))")
        #expect(values.contains { 0.15 < $0 && $0 <= 0.3 }, "no value in the trial band")
        #expect(values.contains { 0.3 < $0 && $0 < 1 }, "no value in the write band")
    }

    /// A 48 kHz session exports to 44.1 kHz: the converter can raise the true peak (0.3 dB in 0032),
    /// so the file is read back. The line has the passes of case (e) of the time table.
    @Test func anExportAtAnotherRateKeepsTheCeiling() throws {
        let options = ExportOptions(format: .wav(.bits24), layout: .stereo, rate: .hz44100, loudness: .podcast)

        let export = try Self.export(Self.train(), options)

        let back = try ExportTests.read(export.url)
        let peak = try #require(try truePeak(back.channels))
        print(
            "anExportAtAnotherRateKeepsTheCeiling: \(1 + export.trials + export.writes) renders, "
                + "\(export.trials) trial passes, \(export.writes) writes, \(export.readBacks) read-backs")
        #expect(back.rate == 44_100)
        #expect(peak <= -1.0, "the read-back true peak: \(peak) dBTP")
        expectLUFS(try measure(back.channels, rate: 44_100).integrated, -16, tolerance: 0.2, "the read-back")
    }
}
