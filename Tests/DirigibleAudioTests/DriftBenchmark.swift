import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Criterion D19 of decision 0077: the drift fix of a 1 h mono clip at 48 kHz at 100 ppm, in a sync
/// span of 2 h, fits its time budgets and 512 MiB of peak footprint in an optimized build
/// (`make bench FILTER=DriftBenchmark`). Each time is the median of 3 runs. A debug build runs a
/// 10 min clip once and only prints the times.
struct DriftBenchmark {
    #if DEBUG
        static let (seconds, runs) = (600, 1)
    #else
        static let (seconds, runs) = (3600, 3)
    #endif
    /// 2 times the first optimized time on the Intel Mac, 8.457 s, rounded up to 0.5 s.
    static let measureBudget: Duration = .seconds(17)
    /// 2 times the first optimized time on the Intel Mac: 6.381 s.
    static let resampleBudget: Duration = .milliseconds(12762)
    /// 2 times the first optimized time on the Intel Mac: 12.494 s.
    static let fullScaleBudget: Duration = .milliseconds(24988)
    /// 2 times the first optimized time on the Intel Mac, 8.612 s, rounded up to 0.5 s.
    static let pausedBudget: Duration = .milliseconds(17500)

    /// The measure is the time from the call to the space check of the new files: the cause checks,
    /// the 0076 read, the windows, the fit, and the cut scan. The resample is the rest: the resample,
    /// the read back, the edit, and the renames. The bench prints the median of `syncLag` on the same
    /// fixture, for the compare with main.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aOneHourClipFitsTheBudget() throws {
        let drift = try Self.twoHourSpan(DriftPackage(seconds: Double(Self.seconds)))
        let (measure, resample, fixes) = try Self.timeFixes(drift)
        let session = drift.package.session
        let span = try session.syncSpan("C", to: "ref")
        var syncs: [Duration] = []
        for _ in 0..<Self.runs {
            let clock = ContinuousClock()
            let start = clock.now
            let sync = try syncLag(of: "C", to: "ref", in: session, package: drift.package.url, span: span)
            syncs.append(clock.now - start)
            let lags = drift.trueLag(0)...drift.trueLag(Double(drift.length))
            #expect(lags.contains(Double(sync.lag.count)), "\(sync)")
        }
        let footprint = peakFootprint()

        let clip = "\(Self.seconds / 60) min clip in a 2 h span"
        Self.report("measure of a \(clip)", measure, footprint)
        Self.report("resample and edit of a \(clip)", resample, footprint)
        Self.report("0076 sync of a \(clip)", syncs, footprint)
        for fix in fixes {
            #expect(fix.splits.isEmpty && fix.clips.count == 1, "\(fix)")
            #expect(abs(fix.slope - drift.m) < 1e-6, "the fit gives \(fix.slope * 1e6) ppm")
        }
        #expect(footprint <= 512 << 20, "peak footprint \(footprint >> 20) MiB")
        expectWithinBudget(Self.median(measure), Self.measureBudget, "the measure took \(Self.median(measure))")
        expectWithinBudget(Self.median(resample), Self.resampleBudget, "the resample took \(Self.median(resample))")
    }

    /// The tone of `StudioDriftTests.tonePackage` peaks at 3.01 dB over full scale, so the resample
    /// writes the file a second time at the scale of A11 and the clip gets the gain back.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aFullScaleHourRunsTheSecondPass() throws {
        let (tone, _) = try StudioDriftTests.tonePackage(
            seconds: Double(Self.seconds), ppm: 100, amplitude: Float(2).squareRoot())
        let drift = try Self.twoHourSpan(tone)
        let (_, resample, _) = try Self.timeFixes(drift) { edited, fix in
            let gain = try #require(edited.clip(fix.clips[0])?.clip.gain)
            #expect(abs(gain.dB - 3.01) < 0.05, "the clip gain is \(gain.dB) dB: no second pass")
        }
        let footprint = peakFootprint()

        Self.report("resample and edit of a full-scale \(Self.seconds / 60) min clip", resample, footprint)
        #expect(footprint <= 512 << 20, "peak footprint \(footprint >> 20) MiB")
        expectWithinBudget(Self.median(resample), Self.fullScaleBudget, "the resample took \(Self.median(resample))")
    }

    /// A 20 s pause at the middle of the clip gives two lines, so the measure holds one cut scan.
    /// The bench times the calls of `driftRequest` up to the cuts: `driftMeasure`, `DriftFit`, and
    /// `driftCuts`. Speech runs through the pause, as in the first case of D9, so the cut is within
    /// 50 ms of it: in a silence, the cut can be anywhere in the silence.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aPausedHourTimesTheCutScan() throws {
        let (pause, at) = (20.0, Double(Self.seconds / 2))
        var voice = DriftSignal(seed: 1, seconds: 30 + Double(Self.seconds) * 1.01 + pause + 60)
        let pauseSource = 30 + at * (1 + 100e-6)
        voice.set(speech: true, in: pauseSource - 10..<pauseSource + pause + 10)
        let drift = try Self.twoHourSpan(
            DriftPackage(seconds: Double(Self.seconds), pause: pause, at: at, voice: voice))
        let (session, url) = (drift.package.session, drift.package.url)
        let span = try session.syncSpan("C", to: "ref")
        var measure: [Duration] = []
        for _ in 0..<Self.runs {
            let clock = ContinuousClock()
            let start = clock.now
            let points = try driftMeasure(of: "C", to: "ref", in: session, package: url, span: span).points
            let fit = try DriftFit(points: points, sampleRate: Double(drift.rate))
            let cuts = try driftCuts(of: "C", to: "ref", in: session, package: url, fit: fit)
            measure.append(clock.now - start)
            #expect(cuts.count == 1 && abs(cuts[0] - drift.pauseAt) <= drift.rate / 20, "the cuts are \(cuts)")
        }
        let footprint = peakFootprint()

        Self.report("measure and cut scan of a paused \(Self.seconds / 60) min clip", measure, footprint)
        #expect(footprint <= 512 << 20, "peak footprint \(footprint >> 20) MiB")
        expectWithinBudget(Self.median(measure), Self.pausedBudget, "the measure took \(Self.median(measure))")
    }
}

extension DriftBenchmark {
    /// Moves both clips of `drift` 1800 s later and fills the reference track with 1800 s of another
    /// voice on each side, so the default span of clip "C" is the clip and 1800 s on each side: 2 h
    /// for a 1 h clip.
    static func twoHourSpan(_ drift: DriftPackage) throws -> DriftPackage {
        let (rate, package) = (drift.rate, drift.package)
        let pad = 1800 * rate
        let reference = try #require(package.session.files["r"]).length
        try package.session.nudge(["R", "C"], by: Frames(pad))
        let step = 1 / Double(rate)
        let other = DriftSignal(seed: 2, seconds: Double(2 * pad + reference.count) * step)
        for (id, start) in [("pre", 0), ("post", pad + reference.count)] {
            try package.addSignal(FileID(id), length: pad) {
                other.samples(start: Double(start + $0.lowerBound) * step, step: step, count: $0.count)
            }
            try package.session.place(
                Clip(id: ClipID(id), file: FileID(id), start: Frames(start), offset: 0, length: Frames(pad)), on: "ref")
        }
        let span = try package.session.syncSpan("C", to: "ref")
        #expect(span.upperBound - span.lowerBound == Frames(drift.length + 2 * pad), "the span is \(span)")
        return drift
    }

    /// Runs `driftRequest` on clip "C" `runs` times and removes the new files after each run. The
    /// space check of the new files splits each run into its measure and its resample. `check` gets
    /// the edited session and the fix of each run.
    static func timeFixes(
        _ drift: DriftPackage, check: (Session, DriftFix) throws -> Void = { _, _ in }
    ) throws -> (measure: [Duration], resample: [Duration], fixes: [DriftFix]) {
        var (measure, resample, fixes): ([Duration], [Duration], [DriftFix]) = ([], [], [])
        for _ in 0..<runs {
            let clock = ContinuousClock()
            let start = clock.now
            var measured: ContinuousClock.Instant?
            let (edited, report, made) = try driftRequest(
                "C", to: "ref", within: nil, of: drift.package.session, in: drift.package.url,
                freeBytes: {
                    measured = clock.now
                    return .max
                })
            let end = clock.now
            let split = try #require(measured, "no space check: \(report.outcome)")
            (measure, resample) = (measure + [split - start], resample + [end - split])
            for url in made { try FileManager.default.removeItem(at: url) }
            let fix = try StudioDriftTests.fix(report)
            try check(edited, fix)
            fixes.append(fix)
        }
        return (measure, resample, fixes)
    }

    static func median(_ times: [Duration]) -> Duration { times.sorted()[times.count / 2] }

    /// One line that `scripts/bench-pairs.sh` reads: the median in seconds, then each run.
    static func report(_ name: String, _ times: [Duration], _ footprint: UInt64) {
        let seconds = { (time: Duration) in
            String(format: "%.3f", Double(time.components.seconds) + Double(time.components.attoseconds) * 1e-18)
        }
        print(
            "DriftBenchmark: \(name) in \(seconds(median(times))) seconds: median of "
                + "[\(times.map(seconds).joined(separator: ", "))], peak footprint \(footprint >> 20) MiB")
    }
}
