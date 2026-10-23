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
    enum Kind: Sendable {
        case silences
        case pause(at: Frames, window: Frames?)
        case meter(step: Frames?)
    }

    let kind: Kind
    let from: Frames
    let to: Frames?
    let tracks: [TrackID]
    let threshold: Gain?
    let minLength: Frames?
    let spelling: OptionSpelling

    /// The most lines of silences or steps in one text.
    static let lineLimit = 1000

    /// Checks the arguments of `silences`: the text of a refusal, for exit 64 or a tool error.
    package static func silences(
        from: Int, to: Int?, tracks: [String], threshold: Double?, minLength: Int?, spelling: OptionSpelling = .tool
    ) -> Result<ReadWork, ToolError> {
        Result { () throws(ToolError) in
            let range = try range(from: from, to: to, spelling)
            return ReadWork(
                kind: .silences, from: range.from, to: range.to, tracks: tracks.map { TrackID($0) },
                threshold: try level(threshold, spelling), minLength: try length(minLength, "min_length", 0, spelling),
                spelling: spelling)
        }
    }

    /// Checks the arguments of `nearest_pause`.
    package static func nearestPause(
        at: Int, window: Int?, tracks: [String], threshold: Double?, minLength: Int?, spelling: OptionSpelling = .tool
    ) -> Result<ReadWork, ToolError> {
        Result { () throws(ToolError) in
            guard isFrame(at) else { throw ToolError("\(spelling("at")) is a frame in 0...2^40.") }
            let width = try length(window, "window", 1, spelling)
            return ReadWork(
                kind: .pause(at: Frames(at), window: width), from: .zero, to: nil, tracks: tracks.map { TrackID($0) },
                threshold: try level(threshold, spelling), minLength: try length(minLength, "min_length", 0, spelling),
                spelling: spelling)
        }
    }

    /// Checks the arguments of `meter`.
    package static func meter(from: Int, to: Int?, tracks: [String], step: Int?, spelling: OptionSpelling = .tool)
        -> Result<ReadWork, ToolError>
    {
        Result { () throws(ToolError) in
            let range = try range(from: from, to: to, spelling)
            return ReadWork(
                kind: .meter(step: try length(step, "step", 1, spelling)), from: range.from, to: range.to,
                tracks: tracks.map { TrackID($0) }, threshold: nil, minLength: nil, spelling: spelling)
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
    /// 0062 at the session rate: threshold -40 dBFS, minimum 500 ms for `silences` and 200 ms for
    /// `nearest_pause`, window 2 s. `silences` and `nearest_pause` read every track of the read
    /// with mute and solo off, and refuse a missing, short, or unreadable file before and after the
    /// scan. `meter` reads the heard mix, and its warning lines name the files that read as silence.
    /// A step refusal comes before the scan. It blocks, so never call it on the main actor.
    package func read(
        _ session: Session, package: URL, progress: (Double) -> Void = { _ in }, isCancelled: () -> Bool = { false }
    ) throws(ReadFailure) -> ReadOutput {
        if let unknown = tracks.first(where: { session.track($0) == nil }) {
            throw .refused(SessionError.unknownTrack(unknown).message)
        }
        let chosen = tracks.isEmpty ? nil : Set(tracks)
        let (rate, end, o) = (session.sampleRate, session.end, spelling)
        // -40 dBFS is in `Gain.range`.
        let threshold = threshold ?? Gain(dB: -40)!
        switch kind {
        case .silences:
            let range = try range(in: session)
            let series = try levels(
                range, chosen, session, package, threshold, progress: progress, isCancelled: isCancelled)
            let silences = series.silences(threshold: threshold, minLength: minLength ?? Frames(rate / 2), in: range)
            return ReadOutput(stdout: Self.silencesLines(silences, spelling: o), stderr: [])
        case .pause(let at, let window):
            guard at < end else { throw .usage("\(o("at")) must be before the session end, frame \(end).") }
            let width = window ?? Frames(2 * rate)
            let asked = max(at - width, .zero)..<min(at + width, end)
            let series = try levels(
                asked, chosen, session, package, threshold, progress: progress, isCancelled: isCancelled)
            let pause = series.nearestPause(
                at: at, window: width, threshold: threshold, minLength: minLength ?? Frames(rate / 5))
            return ReadOutput(stdout: [Self.pauseLine(pause)], stderr: [])
        case .meter(let step):
            let range = try range(in: session)
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
            return ReadOutput(stdout: [line] + steps, stderr: ExportText.faultLines(read.faults, in: session))
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
    private func range(in session: Session) throws(ReadFailure) -> Range<Frames> {
        guard from < session.end else {
            throw .usage("\(spelling("from")) must be before the session end, frame \(session.end).")
        }
        return from..<min(to ?? session.end, session.end)
    }

    /// Refuses a step that is not a whole number of scan windows, or that gives more than
    /// `lineLimit` lines. The steps start on the window grid (decision 0062).
    private func check(_ step: Frames, range: Range<Frames>, session: Session) throws(ReadFailure) {
        let window = max(1, session.sampleRate / 20)
        guard step.count % window == 0 else {
            throw .usage("\(spelling("step")) must be a multiple of the 50 ms window, \(window) frames.")
        }
        let first = range.lowerBound.count / window * window
        let last = min((range.upperBound.count + window - 1) / window * window, session.end.count)
        let count = (last - first + step.count - 1) / step.count
        guard count <= Self.lineLimit else {
            throw .usage(
                "\(spelling("step")) gives \(count) lines, more than \(Self.lineLimit). Give a longer step or a "
                    + "shorter range.")
        }
    }

    /// The window levels of `range` with the silence edge rule. A fault of a file of the read, in
    /// the media check on the session with mute and solo off or in the scan, refuses the read: its
    /// clips would read as silence, so a pause there would be wrong.
    private func levels(
        _ range: Range<Frames>, _ tracks: Set<TrackID>?, _ session: Session, _ package: URL, _ threshold: Gain,
        progress: (Double) -> Void, isCancelled: () -> Bool
    ) throws(ReadFailure) -> LevelSeries {
        var heard = session
        let all = session.tracks.map(\.id)
        // Each ID is in the session, so neither edit can throw.
        try? heard.setMuted(false, tracks: all)
        try? heard.setSoloed(false, tracks: all)
        // The range has a frame in the session, and `tracks` is nil or has a track.
        let source = ExportSource(range: range, tracks: tracks)!
        let faults: [FileID: MediaFault]
        do throws(POSIXError) { faults = try checkMedia(heard, package: package, source: source) } catch {
            throw .refused(mediaCheckMessage(error))
        }
        guard faults.isEmpty else { throw .refused(Self.faultMessage(faults, in: session)) }
        let read: (series: LevelSeries, faults: [FileID: MediaFault])
        do throws(POSIXError) {
            read = try mixLevels(
                of: tracks, in: session, package: package, range: range, silence: threshold, progress: progress,
                isCancelled: isCancelled)
        } catch {
            throw error.code == .ECANCELED ? .cancelled : .refused(audioReadMessage(error))
        }
        guard read.faults.isEmpty else { throw .refused(Self.faultMessage(read.faults, in: session)) }
        return read.series
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
        case .noPause(let cut, let level): "no pause\t\(cut)\t\(value(power(level.meanSquare), "dBFS"))"
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
            return "\($0.frames.lowerBound)\t\(value(power($0.level.meanSquare), "dBFS"))\t\(value(peak, "dBFS"))"
        }
    }

    private static func power(_ meanSquare: Float) -> Double { 10 * log10(Double(meanSquare)) }

    /// A value with one decimal and `unit`, with a plus sign over 0; `none` for no value or no signal.
    private static func value(_ value: Double?, _ unit: String) -> String {
        guard let value, value.isFinite else { return "none" }
        return String(format: value > 0 ? "%+.1f" : "%.1f", value) + " " + unit
    }
}
