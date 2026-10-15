import AVFoundation
import Accelerate
import DirigibleCore
import Foundation

/// Decides each step of an export with a loudness target (decision 0032): trial passes that
/// search the gain on the limited signal, one write, a read-back of the written file where the
/// encoder or the resampler can change it, and a retry round for a true-peak excess or a loudness
/// miss. It does no I/O: `exportMix` runs each step and gives the measurement back to `next`.
///
/// Loudness is a `LUFS`, gain is a `Gain`, and true peak and ceiling are in dBTP. The effective
/// target is the target plus the codec offset in LU: how far the file reads under the limited
/// signal. The ceiling is the one that the limiter gets, the search ceiling.
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
        case trial(gain: Gain, ceiling: Double)
        /// Write the file, and give the limited loudness.
        case write(gain: Gain, ceiling: Double)
        /// Decode the file that the write made, and give its loudness and true peak.
        case readBack
        case done
    }

    /// The measurement of the step that ran. Loudness is nil when no block passes the gates, and
    /// true peak is nil for digital silence. `written` gives the true peak of the signal that the
    /// encoder got.
    enum Event {
        case mix(loudness: LUFS?, truePeak: Double?)
        case trial(output: LUFS?)
        case written(output: LUFS?, truePeak: Double?)
        case readBack(loudness: LUFS?, truePeak: Double?)
    }

    /// A trial stops within this many LU of the effective target.
    static let tolerance = 0.1
    /// A decoded loudness over this many LU from the target starts a loudness retry.
    static let readBackTolerance = 0.2
    /// A decoded true peak over this many dBTP starts a retry.
    static let truePeakLimit = -1.0
    /// A retry puts the ceiling this many dB under the excess of the decoded true peak, counted from
    /// the lower of the ceiling and the written true peak.
    static let retrySlack = 0.1

    let target: LUFS
    private let limits: Limits
    private let readsBack: Bool
    private(set) var effectiveTarget: LUFS
    private(set) var ceiling: Double
    private(set) var trials = 0
    private(set) var writes = 0
    private(set) var readBacks = 0
    private var measured: LUFS?
    private var mixTruePeak: Double?
    private var gain = Gain.zero
    private var points: [(gain: Gain, output: LUFS)] = []
    private var round = 0
    private var capped = false
    private var limited: LUFS?
    private var writtenPeak: Double?

    init(target: LUFS, start: Start, limits: Limits = Limits()) {
        self.target = target
        self.limits = limits
        readsBack = start.readsBack
        effectiveTarget = LUFS(value: target.value + start.offset)
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
                return write((points.isEmpty ? gain : bestPoint().gain).dB)
            }
            points.append((gain, output))
            let best = bestPoint()
            let converged = miss(best.output) <= Self.tolerance
            capped = !converged && points.count >= limits.trialPasses
            if converged || capped { return write(best.gain.dB) }
            let candidate = nextGain()
            if points.contains(where: { abs($0.gain.dB - candidate) < 1e-9 }) {
                capped = true
                return write(best.gain.dB)
            }
            return trial(candidate)
        case .written(let output, let truePeak):
            limited = output
            writtenPeak = truePeak
            return readsBack ? .readBack : .done
        case .readBack(let loudness, let truePeak):
            readBacks += 1
            if measured != nil, let loudness, let limited {
                effectiveTarget = LUFS(value: target.value + limited.value - loudness.value)
            }
            let excess = truePeak.map { $0 > Self.truePeakLimit } ?? false
            let missed =
                loudness.map { measured != nil && abs($0.value - target.value) > Self.readBackTolerance } ?? false
            guard round < limits.retryRounds, excess || (missed && !capped) else { return .done }
            if excess, let truePeak {
                ceiling = min(ceiling, writtenPeak ?? ceiling) - (truePeak - Self.truePeakLimit) - Self.retrySlack
            }
            round += 1
            return begin(after: limited.map { (gain, $0) })
        }
    }

    /// The first step of a round. `previous` is the gain and the limited loudness of the file of
    /// the round before. When the limiter changes no frame at the gain `effective target -
    /// measured`, the limited loudness is the effective target and no trial runs.
    private mutating func begin(after previous: (gain: Gain, output: LUFS)?) -> Step {
        points = []
        capped = false
        guard let measured else { return write(0) }
        let exact = effectiveTarget.value - measured.value
        guard let mixTruePeak, mixTruePeak + exact > ceiling - TruePeakLimiter.margin else { return write(exact) }
        return trial(previous.map { $0.gain.dB + effectiveTarget.value - $0.output.value } ?? exact)
    }

    private mutating func trial(_ candidate: Double) -> Step {
        gain = Gain(clamping: candidate) ?? .zero
        trials += 1
        return .trial(gain: gain, ceiling: ceiling)
    }

    private mutating func write(_ candidate: Double) -> Step {
        gain = Gain(clamping: candidate) ?? .zero
        writes += 1
        return .write(gain: gain, ceiling: ceiling)
    }

    /// The trial point of the round with the smallest miss.
    private func bestPoint() -> (gain: Gain, output: LUFS) {
        points.min { miss($0.output) < miss($1.output) }!
    }

    /// How many LU `output` is from the effective target.
    private func miss(_ output: LUFS) -> Double { abs(output.value - effectiveTarget.value) }

    /// The first step assumes a slope of 1: more gain never makes the limited output quieter and
    /// raises it by at most the gain step (0032), so the step does not pass the target from
    /// below. Later steps use the secant of the last two points, with its slope kept in 0.1...1.
    private func nextGain() -> Double {
        let last = points[points.count - 1]
        let change = effectiveTarget.value - last.output.value
        guard points.count >= 2 else { return last.gain.dB + change }
        let before = points[points.count - 2]
        let rise = last.output.value - before.output.value
        guard abs(rise) > 1e-6 else { return last.gain.dB + change }
        return last.gain.dB + change / min(max(rise / (last.gain.dB - before.gain.dB), 0.1), 1)
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

/// The caps, the start margin, and the hooks of a test or a bench. `exportMix` reads the defaults.
struct ExportTuning {
    var limits = LoudnessSearch.Limits()
    /// Replaces the start margin of the format.
    var startMargin: Double?
    /// Called with each step that `LoudnessSearch` gives, the last `.done` too.
    var onStep: ((LoudnessSearch.Step) -> Void)?
    /// Called with the temporary file after each write and before its read-back.
    var afterWrite: ((URL) -> Void)?
}

/// The bands of the progress value (decision 0032). Pass 1 takes 0...0.15, the trial passes of the
/// first round share 0.15...0.3, and the write takes 0.3...0.75 (0.15...0.75 with no trial pass,
/// and up to 1 with no read-back). The read-back and each retry round share 0.75...1 in equal
/// bands. A retry round gives 40 percent of its band to the trial passes, 50 percent to the write,
/// and 10 percent to the read-back. A band that no step uses is skipped, so the value never goes
/// down. A retry round moves the bar more slowly than the first write. The bar goes to 1 when the
/// export ends.
struct ProgressBands {
    let readsBack: Bool
    let limits: LoudnessSearch.Limits

    let measure = 0.0...0.15

    func trial(round: Int, index: Int) -> ClosedRange<Double> {
        let (low, share) = round == 0 ? (0.15, 0.15) : (roundStart(round), 0.4 * roundWidth)
        let count = Double(max(limits.trialPasses, 1))
        return low + share * Double(index) / count...low + share * Double(index + 1) / count
    }

    func write(round: Int, afterTrials: Bool) -> ClosedRange<Double> {
        if round == 0 { return (afterTrials ? 0.3 : 0.15)...(readsBack ? 0.75 : 1) }
        let low = roundStart(round)
        return (low + (afterTrials ? 0.4 : 0) * roundWidth)...(low + 0.9 * roundWidth)
    }

    func readBack(round: Int) -> ClosedRange<Double> {
        let low = roundStart(round)
        return round == 0 ? low...(low + roundWidth) : (low + 0.9 * roundWidth)...(low + roundWidth)
    }

    private var roundWidth: Double { 0.25 / Double(1 + limits.retryRounds) }

    /// Round 0 is the read-back of the first write, and round k is the k-th retry round.
    private func roundStart(_ round: Int) -> Double { 0.75 + roundWidth * Double(round) }
}

/// The gain, the limiter at the ceiling of the search, and the meters of one pass over the mix.
struct LoudnessStage {
    let gain: Gain
    private let factor: Float
    private var limiter: TruePeakLimiter
    private var loudness: LoudnessMeter?
    private var truePeakMeter: TruePeakMeter?

    init(gain: Gain, ceiling: Double, rate: Int, layout: ChannelLayout, measuresTruePeak: Bool) {
        self.gain = gain
        factor = Float(pow(10, gain.dB / 20))
        limiter = TruePeakLimiter(ceiling: ceiling, rate: rate, layout: layout)
        loudness = LoudnessMeter(sampleRate: rate, layout: layout)
        truePeakMeter = measuresTruePeak ? TruePeakMeter(layout: layout) : nil
    }

    /// The gain and the limiter, in place. The frame count can go down (the look-ahead).
    mutating func process(_ buffer: AVAudioPCMBuffer) {
        var scale = factor
        for channel in 0..<Int(buffer.format.channelCount) {
            let samples = buffer.floatChannelData![channel]
            vDSP_vsmul(samples, 1, &scale, samples, 1, vDSP_Length(buffer.frameLength))
        }
        limiter.process(buffer)
    }

    /// The last frames of the limiter into `buffer`. False when it has none left.
    mutating func drain(into buffer: AVAudioPCMBuffer) -> Bool { limiter.drain(into: buffer) }

    mutating func measure(_ buffer: AVAudioPCMBuffer) {
        loudness?.feed(buffer)
        truePeakMeter?.feed(buffer)
    }

    /// The loudness of the limited signal. Nil with no gated block.
    var output: LUFS? { loudness?.result().integrated }
    /// The true peak of the limited signal. Nil for digital silence, and when the pass has no
    /// true-peak meter.
    var truePeak: Double? { truePeakMeter?.result() }
}

/// The loudness and the true peak of a file.
struct FileMeasure {
    var loudness: LUFS?
    var truePeak: Double?
}

/// Decodes the audio file at `url` as macOS decodes it (AudioToolbox), and measures its loudness
/// and true peak at the file rate. `progress` gets the fraction done. It reads `isCancelled` at
/// each chunk. A file that Core Audio cannot open or read throws `.writeFailed` with its status.
/// The decode must give at least `frames` frames, else the values are those of a prefix and it
/// throws `.writeFailed`. This check has two limits. An MP3 file that Core Audio does not trim counts
/// its encoder delay and padding, so a decode that ends up to one MP3 frame (1152 frames) early
/// passes. A read that fails after `frames` frames ends the file for every format, and the frames
/// after the failure are not measured.
func measureDecodedFile(
    _ url: URL, layout: ChannelLayout, frames: Int, isCancelled: () -> Bool, progress: (Double) -> Void
) throws(ExportError) -> FileMeasure {
    let file: AVAudioFile
    do { file = try AVAudioFile(forReading: url) } catch { throw .writeFailed(status(of: error)) }
    let rate = Int(file.processingFormat.sampleRate)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(rate))
    else { throw .writeFailed(kAudio_ParamError) }
    var loudness = LoudnessMeter(sampleRate: rate, layout: layout)
    var peak = TruePeakMeter(layout: layout)
    var read = 0
    while file.framePosition < file.length {
        if isCancelled() { throw .cancelled }
        do { try file.read(into: buffer) } catch {
            if read >= frames { break }
            throw .writeFailed(status(of: error))
        }
        if buffer.frameLength == 0 { break }
        loudness?.feed(buffer)
        peak.feed(buffer)
        read += Int(buffer.frameLength)
        progress(Double(file.framePosition) / Double(file.length))
    }
    guard read >= frames else { throw .writeFailed(kAudioFileEndOfFileError) }
    return FileMeasure(loudness: loudness?.result().integrated, truePeak: peak.result())
}
