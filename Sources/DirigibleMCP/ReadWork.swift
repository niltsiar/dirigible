import DirigibleAudio
import DirigibleCore
import Foundation

/// Why a read gives no text: a bad argument (CLI exit 64), a refusal (CLI exit 2: an unknown
/// track, a missing, short, or unreadable file of `silences` and `nearest_pause`, or an audio
/// file that cannot open), or a cancel.
package enum ReadFailure: Error, Equatable, Sendable {
    case usage(String)
    case refused(String)
    case cancelled

    package var message: String {
        switch self {
        case .usage(let text), .refused(let text): text
        case .cancelled: cancelledMessage
        }
    }
}

/// The lines of a read: the warning lines on stderr, the result lines on stdout.
package struct ReadOutput: Equatable, Sendable {
    package let stdout: [String]
    package let stderr: [String]
    /// The text of the tool: the warning lines first, as the stderr and stdout of the command.
    package var text: String { (stderr + stdout).joined(separator: "\n") }
}

/// The work of a `silences`, `nearest_pause`, or `meter` call or command after its arguments are
/// checked (decisions 0049 and 0062). It is the one owner of the argument rules, the read, and the
/// texts of the three commands and their tools. On the files it reads with no lock; in the app,
/// `liveJob` runs `read` on the session of the window.
package struct ReadWork: Sendable {
    /// The checked arguments of each read; nil takes the default of decision 0062.
    enum Kind: Sendable {
        case silences(from: Frames, to: Frames?, threshold: Gain?, minLength: Frames?)
        case pause(at: Frames, window: Frames?, threshold: Gain?, minLength: Frames?)
        case meter(from: Frames, to: Frames?, step: Frames?)
    }

    let kind: Kind
    let tracks: [TrackID]
    let spelling: OptionSpelling

    /// The most lines of silences or steps in one text.
    static let lineLimit = 1000

    /// Checks the arguments of `silences`: the text of a refusal, for exit 64 or a tool error.
    package static func silences(
        from: Int, to: Int?, tracks: [String], threshold: Double?, minLength: Int?, spelling: OptionSpelling = .tool
    ) -> Result<ReadWork, ToolError> {
        Result { () throws(ToolError) in
            let range = try range(from: from, to: to, spelling)
            let kind = Kind.silences(
                from: range.from, to: range.to, threshold: try level(threshold, spelling),
                minLength: try length(minLength, "min_length", 0, spelling))
            return ReadWork(kind: kind, tracks: tracks.map { TrackID($0) }, spelling: spelling)
        }
    }

    /// Checks the arguments of `nearest_pause`.
    package static func nearestPause(
        at: Int, window: Int?, tracks: [String], threshold: Double?, minLength: Int?, spelling: OptionSpelling = .tool
    ) -> Result<ReadWork, ToolError> {
        Result { () throws(ToolError) in
            guard isFrame(at) else { throw ToolError("\(spelling("at")) is a frame in 0...2^40.") }
            let kind = Kind.pause(
                at: Frames(at), window: try length(window, "window", 1, spelling),
                threshold: try level(threshold, spelling), minLength: try length(minLength, "min_length", 0, spelling))
            return ReadWork(kind: kind, tracks: tracks.map { TrackID($0) }, spelling: spelling)
        }
    }

    /// Checks the arguments of `meter`.
    package static func meter(from: Int, to: Int?, tracks: [String], step: Int?, spelling: OptionSpelling = .tool)
        -> Result<ReadWork, ToolError>
    {
        Result { () throws(ToolError) in
            let range = try range(from: from, to: to, spelling)
            let kind = Kind.meter(from: range.from, to: range.to, step: try length(step, "step", 1, spelling))
            return ReadWork(kind: kind, tracks: tracks.map { TrackID($0) }, spelling: spelling)
        }
    }

    private static func isFrame(_ value: Int) -> Bool { (0...Frames.limit.count).contains(value) }

    private static func range(from: Int, to: Int?, _ o: OptionSpelling) throws(ToolError) -> (from: Frames, to: Frames?)
    {
        guard isFrame(from), to.map({ isFrame($0) && $0 > from }) ?? true else {
            throw ToolError("\(o("from")) is a frame in 0...2^40, and \(o("to")) is more than \(o("from")).")
        }
        return (Frames(from), to.map { Frames($0) })
    }

    private static func level(_ value: Double?, _ o: OptionSpelling) throws(ToolError) -> Gain? {
        guard let value else { return nil }
        guard value < 0, let gain = Gain(dB: value) else {
            throw ToolError("\(o("threshold")) is a dB value under 0 and not under -96.")
        }
        return gain
    }

    private static func length(_ value: Int?, _ key: String, _ minimum: Int, _ o: OptionSpelling) throws(ToolError)
        -> Frames?
    {
        guard let value else { return nil }
        guard (minimum...Frames.limit.count).contains(value) else {
            throw ToolError("\(o(key)) is a length in frames in \(minimum)...2^40.")
        }
        return Frames(value)
    }

    /// The read of `session`, whose audio files are in `package`, with the defaults of decision
    /// 0062 at the session rate: the duck threshold, -40 dBFS; minimum 500 ms for `silences` and 200 ms for
    /// `nearest_pause`, window 2 s. `silences` and `nearest_pause` read every track of the read
    /// with mute and solo off, and refuse a missing, short, or unreadable file before and after the
    /// scan. `meter` reads the heard mix, and its warning lines are those of a stereo export of the
    /// range: the files that read as silence, then the tracks that are not heard.
    /// A step refusal comes before the scan. It blocks, so never call it on the main actor.
    package func read(
        _ session: Session, package: URL, progress: (Double) -> Void = { _ in }, isCancelled: () -> Bool = { false }
    ) throws(ReadFailure) -> ReadOutput {
        if let unknown = tracks.first(where: { session.track($0) == nil }) {
            throw .refused(SessionError.unknownTrack(unknown).message)
        }
        let chosen = tracks.isEmpty ? nil : Set(tracks)
        let (rate, end, o) = (session.sampleRate, session.end, spelling)
        let quiet = DuckShape.defaults(sampleRate: rate).threshold
        switch kind {
        case .silences(let from, let to, let level, let minLength):
            let (range, threshold) = (try range(from, to, in: session), level ?? quiet)
            let series = try levels(
                range, chosen, session, package, threshold, progress: progress, isCancelled: isCancelled)
            let silences = series.silences(threshold: threshold, minLength: minLength ?? Frames(rate / 2), in: range)
            return ReadOutput(
                stdout: Self.silencesLines(silences, spelling: o), stderr: Self.limitLines(silences, series, end: end))
        case .pause(let at, let window, let level, let minLength):
            let threshold = level ?? quiet
            guard at < end else { throw .usage("\(o("at")) must be before the session end, frame \(end).") }
            let width = window ?? Frames(2 * rate)
            let asked = max(at - width, .zero)..<min(at + width, end)
            let series = try levels(
                asked, chosen, session, package, threshold, progress: progress, isCancelled: isCancelled)
            let pause = series.nearestPause(
                at: at, window: width, threshold: threshold, minLength: minLength ?? Frames(rate / 5))
            let reported: [Range<Frames>] = if case .pause(let silence, _) = pause { [silence] } else { [] }
            return ReadOutput(stdout: [Self.pauseLine(pause)], stderr: Self.limitLines(reported, series, end: end))
        case .meter(let from, let to, let step):
            let range = try range(from, to, in: session)
            if let step { try check(step, range: range, session: session) }
            let read: (measure: MixMeasure, series: LevelSeries, faults: [FileID: MediaFault])
            do throws(POSIXError) {
                read = try measureMix(
                    of: chosen, in: session, package: package, range: range, progress: progress,
                    isCancelled: isCancelled)
            } catch {
                throw error.code == .ECANCELED ? .cancelled : .refused(audioReadMessage(error))
            }
            let line = Self.meterLine(read.measure, length: range.upperBound - range.lowerBound, rate: rate)
            let steps = step.map { Self.stepLines(read.series.steps(of: $0)) } ?? []
            // The range has a frame in the session, and `chosen` is nil or has a track.
            let source = ExportSource(range: range, tracks: chosen)!
            let warnings =
                ExportText.faultLines(read.faults, in: session) + ExportText.unheardLines(session, source: source)
            return ReadOutput(stdout: [line] + steps, stderr: warnings)
        }
    }

    /// The job of a tool call on the files, with no lock.
    func run(_ package: URL, path: String, control: CallControl) throws(ToolError) -> String {
        let session: Session
        do throws(SessionFileError) { session = try Session(contentsOf: package) } catch {
            throw ToolError(error.message(package: path))
        }
        do throws(ReadFailure) {
            return try read(session, package: package, progress: control.report, isCancelled: control.isCancelled).text
        } catch {
            throw ToolError(error.message)
        }
    }

    /// `from ..< to`, with `to` cut to the session end.
    private func range(_ from: Frames, _ to: Frames?, in session: Session) throws(ReadFailure) -> Range<Frames> {
        guard from < session.end else {
            throw .usage("\(spelling("from")) must be before the session end, frame \(session.end).")
        }
        return from..<min(to ?? session.end, session.end)
    }

    /// Refuses a step that is not a whole number of scan windows, or that gives more than
    /// `lineLimit` lines. The steps start on the window grid (decision 0062).
    private func check(_ step: Frames, range: Range<Frames>, session: Session) throws(ReadFailure) {
        let window = LevelSeries.window(rate: session.sampleRate).count
        guard step.count % window == 0 else {
            throw .usage("\(spelling("step")) must be a multiple of the 50 ms window, \(window) frames.")
        }
        let grid = LevelSeries.grid(of: range, rate: session.sampleRate, end: session.end)
        let count = (grid.upperBound.count - grid.lowerBound.count + step.count - 1) / step.count
        guard count <= Self.lineLimit else {
            throw .usage(
                "\(spelling("step")) gives \(count) lines, more than \(Self.lineLimit). Give a longer step or a "
                    + "shorter range.")
        }
    }

    /// The window levels of `range` with the silence edge rule. A fault of a file of the read, in
    /// the media check on `Session.ignoringMuteAndSolo` or in the scan, refuses the read: its
    /// clips would read as silence, so a pause there would be wrong.
    private func levels(
        _ range: Range<Frames>, _ tracks: Set<TrackID>?, _ session: Session, _ package: URL, _ threshold: Gain,
        progress: (Double) -> Void, isCancelled: () -> Bool
    ) throws(ReadFailure) -> LevelSeries {
        do throws(CheckedReadError) {
            return try checkedMixLevels(
                of: tracks, in: session, package: package, range: range, silence: threshold, progress: progress,
                isCancelled: isCancelled)
        } catch {
            throw Self.failure(error, in: session)
        }
    }

    /// The refusal of `silences` and `nearest_pause` for each step of `checkedMixLevels`.
    static func failure(_ error: CheckedReadError, in session: Session) -> ReadFailure {
        switch error {
        case .check(let error): .refused(mediaCheckMessage(error))
        case .read(let error): error.code == .ECANCELED ? .cancelled : .refused(audioReadMessage(error))
        case .faults(let faults): .refused(faultMessage(faults, in: session))
        case .badSource: .refused(audioReadMessage(POSIXError(.EINVAL)))
        }
    }

    /// One warning line for each edge of `series` that a silence of `silences` reaches, unless it is
    /// a session edge: there the scan stopped at its limit, so the silence can go on.
    static func limitLines(_ silences: [Range<Frames>], _ series: LevelSeries, end: Frames) -> [String] {
        let edges = [series.range.lowerBound, series.range.upperBound].filter { edge in
            edge != .zero && edge != end && silences.contains { $0.lowerBound == edge || $0.upperBound == edge }
        }
        return edges.map {
            "Warning: a silence can go on beyond frame \($0), the read limit \(LevelSeries.edgeWindows / 20) s outside "
                + "the range; its line stops there."
        }
    }

    /// The refusal of `silences` and `nearest_pause` for files that read as silence.
    static func faultMessage(_ faults: [FileID: MediaFault], in session: Session) -> String {
        "\(ExportText.files(faults, in: session)); its clips would read as silence, so the read gives no silence or "
            + "pause. Restore the file, or read a range or tracks without it."
    }

    /// One line `<start>\t<end>` for each silence, at most `lineLimit`, then a line with the count
    /// of the others; `No silence.` when none.
    static func silencesLines(_ silences: [Range<Frames>], spelling o: OptionSpelling) -> [String] {
        guard !silences.isEmpty else { return ["No silence."] }
        let lines = silences.prefix(lineLimit).map { "\($0.lowerBound)\t\($0.upperBound)" }
        let more = silences.count - lineLimit
        guard more > 0 else { return lines }
        return lines + ["\(more) more silences: give a shorter range or a longer \(o("min_length"))."]
    }

    /// `pause\t<start>\t<end>\t<cut>`, or `no pause\t<cut>\t<level> dBFS`.
    static func pauseLine(_ pause: Pause) -> String {
        switch pause {
        case .pause(let silence, let cut): "pause\t\(silence.lowerBound)\t\(silence.upperBound)\t\(cut)"
        case .noPause(let cut, let level): "no pause\t\(cut)\t\(dBFS(power(level.meanSquare)))"
        }
    }

    /// The values of the heard stereo mix of a range of `length` frames. EBU R 128 s1: the loudness
    /// range does not apply to a range under 2 min.
    static func meterLine(_ measure: MixMeasure, length: Frames, rate: Int) -> String {
        let range =
            length.count < 120 * rate
            ? "none (under 2 min)" : measure.loudnessRange.map { String(format: "%.1f LU", $0) } ?? "none"
        return "heard stereo mix: loudness \(value(measure.integrated?.value, "LUFS")), range \(range), max momentary "
            + "\(value(measure.maxMomentary?.value, "LUFS")), max short-term \(value(measure.maxShortTerm?.value, "LUFS")), "
            + "true peak \(value(measure.truePeak, "dBTP")), peak \(value(measure.samplePeak, "dBFS"))"
    }

    /// One line `<start>\t<RMS> dBFS\t<peak> dBFS` for each step.
    static func stepLines(_ steps: [LevelSeries.Step]) -> [String] {
        steps.map {
            let peak = 20 * log10(Double($0.level.peak))
            return "\($0.frames.lowerBound)\t\(dBFS(power($0.level.meanSquare)))\t\(dBFS(peak))"
        }
    }

    private static func power(_ meanSquare: Float) -> Double { 10 * log10(Double(meanSquare)) }

    /// A level column: digital silence is `-inf dBFS`, so the column has one form (decision 0062).
    private static func dBFS(_ level: Double) -> String { level == -.infinity ? "-inf dBFS" : value(level, "dBFS") }

    /// A value with one decimal and `unit`, with a plus sign over 0; `none` for no value or no signal.
    private static func value(_ value: Double?, _ unit: String) -> String {
        guard let value, value.isFinite else { return "none" }
        return String(format: value > 0 ? "%+.1f" : "%.1f", value) + " " + unit
    }
}
