import DirigibleCore
import Foundation

/// Decides each step of an export with a loudness target (decision 0032): trial passes that
/// search the gain on the limited signal, one write, a read-back of the written file where the
/// encoder or the resampler can change it, and a retry round for a true-peak excess or a loudness
/// miss. It does no I/O: `exportMix` runs each step and gives the measurement back to `next`.
///
/// Loudness is in LUFS, true peak in dBTP, and gain in dB. The effective target is the target plus
/// the codec offset: how far the file reads under the limited signal. The ceiling is the one that
/// the limiter gets, the search ceiling.
struct LoudnessSearch {
    /// The caps. The trial cap counts in each round.
    struct Limits: Equatable {
        var trialPasses = 4
        var retryRounds = 2
    }

    /// The start values of a file. The margin is how many dB under -1 dBTP the first ceiling is,
    /// and the offset is the codec offset before a read-back.
    struct Start: Equatable {
        var margin: Double
        var offset: Double
        var readsBack: Bool
    }

    enum Step: Equatable {
        /// Render with no file at this gain and ceiling, and give the limited loudness.
        case trial(gain: Double, ceiling: Double)
        /// Write the file, and give the limited loudness.
        case write(gain: Double, ceiling: Double)
        /// Decode the file that the write made, and give its loudness and true peak.
        case readBack
        case done
    }

    /// The measurement of the step that ran. Loudness is nil when no block passes the gates, and
    /// true peak is nil for digital silence.
    enum Event {
        case mix(loudness: Double?, truePeak: Double?)
        case trial(output: Double?)
        case written(output: Double?)
        case readBack(loudness: Double?, truePeak: Double?)
    }

    /// A trial stops within this many LU of the effective target.
    static let tolerance = 0.1
    /// A decoded loudness over this many LU from the target starts a loudness retry.
    static let readBackTolerance = 0.2
    /// A decoded true peak over this many dBTP starts a retry.
    static let truePeakLimit = -1.0
    /// A retry puts the ceiling this many dB under the decoded true peak.
    static let retrySlack = 0.1

    let target: Double
    private let limits: Limits
    private let readsBack: Bool
    private(set) var effectiveTarget: Double
    private(set) var ceiling: Double
    private(set) var trials = 0
    private(set) var writes = 0
    private(set) var readBacks = 0
    private var measured: Double?
    private var mixTruePeak: Double?
    private var gain = 0.0
    private var points: [(gain: Double, output: Double)] = []
    private var round = 0
    private var capped = false
    private var limited: Double?

    init(target: Double, start: Start, limits: Limits = Limits()) {
        self.target = target
        self.limits = limits
        readsBack = start.readsBack
        effectiveTarget = target + start.offset
        ceiling = Self.truePeakLimit - start.margin
    }

    mutating func next(after event: Event) -> Step {
        switch event {
        case .mix(let loudness, let truePeak):
            measured = loudness
            mixTruePeak = truePeak
            return begin(after: nil)
        case .trial(let output):
            guard let output else {
                capped = true
                return write(points.isEmpty ? gain : bestPoint().gain)
            }
            points.append((gain, output))
            let best = bestPoint()
            let converged = abs(best.output - effectiveTarget) <= Self.tolerance
            capped = !converged && points.count >= limits.trialPasses
            if converged || capped { return write(best.gain) }
            let candidate = nextGain()
            if points.contains(where: { abs($0.gain - candidate) < 1e-9 }) {
                capped = true
                return write(best.gain)
            }
            return trial(candidate)
        case .written(let output):
            limited = output
            return readsBack ? .readBack : .done
        case .readBack(let loudness, let truePeak):
            readBacks += 1
            if measured != nil, let loudness, let limited { effectiveTarget = target + limited - loudness }
            let excess = truePeak.map { $0 > Self.truePeakLimit } ?? false
            let missed = loudness.map { measured != nil && abs($0 - target) > Self.readBackTolerance } ?? false
            guard round < limits.retryRounds, excess || (missed && !capped) else { return .done }
            if excess, let truePeak { ceiling -= truePeak - Self.truePeakLimit + Self.retrySlack }
            round += 1
            return begin(after: limited.map { (gain, $0) })
        }
    }

    /// The first step of a round. `previous` is the gain and the limited loudness of the file of
    /// the round before. When the limiter changes no frame at the gain `effective target -
    /// measured`, the limited loudness is the effective target and no trial runs.
    private mutating func begin(after previous: (gain: Double, output: Double)?) -> Step {
        points = []
        capped = false
        guard let measured else { return write(0) }
        let exact = effectiveTarget - measured
        guard let mixTruePeak, mixTruePeak + exact > ceiling - TruePeakLimiter.margin else { return write(exact) }
        return trial(previous.map { $0.gain + effectiveTarget - $0.output } ?? exact)
    }

    private mutating func trial(_ candidate: Double) -> Step {
        gain = Gain(clamping: candidate)?.dB ?? 0
        trials += 1
        return .trial(gain: gain, ceiling: ceiling)
    }

    private mutating func write(_ candidate: Double) -> Step {
        gain = Gain(clamping: candidate)?.dB ?? 0
        writes += 1
        return .write(gain: gain, ceiling: ceiling)
    }

    /// The trial point of the round with the smallest miss.
    private func bestPoint() -> (gain: Double, output: Double) {
        points.min { abs($0.output - effectiveTarget) < abs($1.output - effectiveTarget) }!
    }

    /// The first step assumes a slope of 1: more gain never makes the limited output quieter and
    /// raises it by at most the gain step (0032), so the step does not pass the target from
    /// below. Later steps use the secant of the last two points, with its slope kept in 0.1...1.
    private func nextGain() -> Double {
        let last = points[points.count - 1]
        let change = effectiveTarget - last.output
        guard points.count >= 2 else { return last.gain + change }
        let before = points[points.count - 2]
        let rise = last.output - before.output
        guard abs(rise) > 1e-6 else { return last.gain + change }
        return last.gain + change / min(max(rise / (last.gain - before.gain), 0.1), 1)
    }
}

extension LoudnessSearch.Start {
    /// AAC: a margin of 1.5 dB. MP3: 0.5 dB, and the LAME scale of 0034 U4 as the offset. A
    /// lossless file at another rate: 0.3 dB, the resampler figure of 0032. Probes U10, U19, U24.
    init(format: ExportFormat, fileRate: Int, sessionRate: Int) {
        switch format {
        case .aac:
            self.init(margin: 1.5, offset: 0, readsBack: true)
        case .mp3(let bitRate):
            let scale: Double =
                switch bitRate {
                case .k64, .k96, .k128, .k160: 0.45
                case .k192: 0.26
                case .k256: 0
                }
            self.init(margin: 0.5, offset: scale, readsBack: true)
        case .wav, .flac, .floatCAF:
            let resampled = fileRate != sessionRate
            self.init(margin: resampled ? 0.3 : 0, offset: 0, readsBack: resampled)
        }
    }
}
