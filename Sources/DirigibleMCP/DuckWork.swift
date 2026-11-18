import DirigibleAudio
import DirigibleCore
import Foundation

/// Why a duck changes nothing: the session refuses it, an audio file cannot open, or a cancel
/// stops it.
package enum DuckFailure: Error {
    case session(SessionError)
    case audio(POSIXError)
    case cancelled

    package var message: String {
        switch self {
        case .session(let error): error.message
        case .audio(let error): audioReadMessage(error)
        case .cancelled: "the duck was cancelled."
        }
    }
}

/// The work of a `duck` call or command after its arguments are checked (decisions 0049 and 0060).
/// It is the one owner of the argument rules, the steps on the files, and the texts of
/// `dirigible duck` and the `duck` tool. In the app, `liveJob` runs `Studio.duck`.
package struct DuckWork: Sendable {
    let speech: [TrackID]
    let music: [TrackID]
    let range: Range<Frames>?
    let depth: Gain?
    let attack: Frames?
    let release: Frames?
    let threshold: Gain?
    let hold: Frames?

    /// Checks the arguments: the text of a refusal, for exit 64 or a tool error. `from` and `to`
    /// come together, with `from < to`; depth and threshold are under 0 dB and over -96 dB;
    /// attack, release, and hold are lengths in 0...2^40.
    package static func parse(
        speech: [String], music: [String], from: Int?, to: Int?, depth: Double?, attack: Int?, release: Int?,
        threshold: Double?, hold: Int?
    ) -> Result<DuckWork, ToolError> {
        var range: Range<Frames>?
        switch (from, to) {
        case (nil, nil): range = nil
        case (let from?, let to?)
        where (0...Frames.limit.count).contains(from) && (0...Frames.limit.count).contains(to) && from < to:
            range = Frames(from)..<Frames(to)
        default: return .failure(ToolError("from and to come together, as frames in 0...2^40 with from < to."))
        }
        func level(_ value: Double?) -> Gain?? {
            guard let value else { return .some(nil) }
            guard value < 0, let gain = Gain(dB: value) else { return nil }
            return gain
        }
        func length(_ value: Int?) -> Frames?? {
            guard let value else { return .some(nil) }
            guard (0...Frames.limit.count).contains(value) else { return nil }
            return Frames(value)
        }
        guard let depth = level(depth), let threshold = level(threshold) else {
            return .failure(ToolError("depth and threshold are dB values under 0 and not under -96."))
        }
        guard let attack = length(attack), let release = length(release), let hold = length(hold) else {
            return .failure(ToolError("attack, release, and hold are lengths in frames in 0...2^40."))
        }
        return .success(
            DuckWork(
                speech: speech.map { TrackID($0) }, music: music.map { TrackID($0) }, range: range, depth: depth,
                attack: attack, release: release, threshold: threshold, hold: hold))
    }

    /// The shape with the defaults of decision 0060 at `sampleRate` for each value not given.
    func shape(sampleRate: Int) -> DuckShape {
        let base = DuckShape.defaults(sampleRate: sampleRate)
        return DuckShape(
            depth: depth ?? base.depth, attack: attack ?? base.attack, release: release ?? base.release,
            threshold: threshold ?? base.threshold, hold: hold ?? base.hold)
    }

    /// The track lists, the scope (`Session.duckScope`), and the shape of the duck in `session`.
    package func plan(in session: Session) throws(SessionError) -> (
        speech: [TrackID], music: [TrackID], scope: Range<Frames>, shape: DuckShape
    ) {
        let (speech, music) = try session.duckTracks(speech: speech, music: music)
        return (speech, music, try session.duckScope(range), shape(sampleRate: session.sampleRate))
    }

    /// The duck in `session`: the stdout lines and the report line of the command. The flag is read
    /// last before the caller saves: a cancel keeps `session` as it was and throws `.cancelled`.
    package func run(
        _ session: inout Session, package: URL, progress: @escaping @Sendable (Double) -> Void = { _ in },
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws(DuckFailure) -> (lines: [String], report: String) {
        let planned: (speech: [TrackID], music: [TrackID], scope: Range<Frames>, shape: DuckShape)
        do throws(SessionError) { planned = try plan(in: session) } catch { throw .session(error) }
        let read: (runs: [Range<Frames>], unread: [FileID])
        do throws(POSIXError) {
            read = try speechRuns(
                of: planned.speech, in: session, package: package, scope: planned.scope, shape: planned.shape,
                progress: progress, isCancelled: isCancelled)
        } catch {
            throw error.code == .ECANCELED ? .cancelled : .audio(error)
        }
        guard !isCancelled() else { throw .cancelled }
        var ducked = session
        let result: DuckResult
        do throws(SessionError) {
            result = try ducked.duck(
                runs: read.runs, unread: read.unread, shape: planned.shape, music: planned.music, scope: range)
        } catch {
            throw .session(error)
        }
        session = ducked
        return (Self.lines(result), Self.text(of: result))
    }

    /// One line for each speech run (`speech`, its first frame, and the frame after its end), then
    /// one line for each ducked clip (`ducked` and the ID), then one for each reached clip with no
    /// change (`unchanged`), then one for each kept clip (`kept`), then one for each speech file
    /// that did not read (`unread` and the file ID).
    package static func lines(_ result: DuckResult) -> [String] {
        result.runs.map { "speech\t\($0.lowerBound)\t\($0.upperBound)" } + result.ducked.map { "ducked\t\($0)" }
            + result.unchanged.map { "unchanged\t\($0)" } + result.kept.map { "kept\t\($0)" }
            + result.unread.map { "unread\t\($0)" }
    }

    /// The report line.
    package static func text(of result: DuckResult) -> String {
        var text =
            "Speech runs: \(result.runs.count). Clips ducked: \(result.ducked.count), with \(result.points) points."
        if !result.unchanged.isEmpty {
            text += " Clips that speech reaches with no change: \(result.unchanged.count)."
        }
        if !result.kept.isEmpty {
            text += " Clips that no speech reaches keep their envelope: \(result.kept.count)."
        }
        if !result.unread.isEmpty {
            text += " Speech files that did not read: \(result.unread.count). The music stays up over their speech."
        }
        return text
    }

    /// The job of a tool call on the files, under the package lock. A duck that changes no point
    /// writes nothing.
    func run(_ package: URL, path: String, control: CallControl) throws(ToolError) -> String {
        do throws(EditFailure<DuckFailure>) {
            let result = try editPackageCore(package, ripple: false, writeUnchanged: false, log: control.log) {
                session, _ throws(DuckFailure) in
                try run(
                    &session, package: package, progress: { control.report($0) },
                    isCancelled: { control.isCancelled() })
            }
            return (result.lines + [result.report]).joined(separator: "\n")
        } catch .body(.cancelled) {
            // A cancelled call gets no answer, so no one reads this text.
            throw ToolError(cancelledMessage)
        } catch {
            throw ToolError(error.message(package: path))
        }
    }
}
