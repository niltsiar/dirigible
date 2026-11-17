import DirigibleAudio
import DirigibleCore
import Foundation

/// The work of a `track_match_voice` call or a `dirigible track match-voice` command after its
/// arguments are checked (decisions 0049 and 0074). It is the one owner of the argument rules,
/// the steps on the files, and the lines of the command and the tool. In the app, `liveJob` runs
/// `Studio.matchVoice` for `.set`, and an edit runs the other modes.
package struct MatchWork: Sendable {
    package enum Mode: Sendable, Equatable {
        /// A new match from the reference clip, or a replace. A nil amount gives 75 for a track
        /// with no match and keeps the amount of a track with one.
        case set(Request)
        /// An edit that reads no audio.
        case edit(Edit)
    }

    /// A match from the reference clip `reference`: its frames in `range` (timeline frames), else
    /// the whole clip.
    package struct Request: Sendable, Equatable {
        package let reference: ClipID
        package let range: Range<Frames>?
        package let amount: VoiceMatch.Amount?
    }

    package enum Edit: Sendable, Equatable {
        /// The amount, the bypass, or both of tracks that have a match.
        case change(amount: VoiceMatch.Amount?, bypassed: Bool?)
        case remove
    }

    package let tracks: [TrackID]
    package let mode: Mode

    /// The bypass word of the command: `on` or `off`.
    package static func bypass(word: String) -> Bool? {
        switch word {
        case "on": true
        case "off": false
        default: nil
        }
    }

    /// Checks the arguments: the text of a refusal, for exit 64 or a tool error. One or more
    /// tracks. `remove` goes with nothing else. `reference` starts a match, with `from` and `to`
    /// together as frames in 0...2^40 with `from < to`, and an amount from 1 to 100; a new match is
    /// on, so `bypass` does not go with it. With no `reference`, give `amount`, `bypass`, or both.
    package static func parse(
        tracks: [String], reference: String?, from: Int?, to: Int?, amount: Int?, bypass: Bool?, remove: Bool
    ) -> Result<MatchWork, ToolError> {
        guard !tracks.isEmpty else { return .failure(ToolError("Give one or more tracks.")) }
        var seen = Set<TrackID>()
        let ids = tracks.map { TrackID($0) }.filter { seen.insert($0).inserted }
        if remove {
            guard reference == nil, from == nil, to == nil, amount == nil, bypass == nil else {
                return .failure(ToolError("remove does not go with reference, from, to, amount, or bypass."))
            }
            return .success(MatchWork(tracks: ids, mode: .edit(.remove)))
        }
        var range: Range<Frames>?
        switch (from, to) {
        case (nil, nil): range = nil
        case (let from?, let to?)
        where (0...Frames.limit.count).contains(from) && (0...Frames.limit.count).contains(to) && from < to:
            range = Frames(from)..<Frames(to)
        default: return .failure(ToolError("from and to come together, as frames in 0...2^40 with from < to."))
        }
        var percent: VoiceMatch.Amount?
        if let amount {
            guard let checked = VoiceMatch.Amount(amount) else {
                return .failure(ToolError("amount is a whole percent from 1 to 100."))
            }
            percent = checked
        }
        if let reference {
            guard bypass == nil else {
                return .failure(ToolError("bypass does not go with reference: a new match is on."))
            }
            return .success(
                MatchWork(tracks: ids, mode: .set(Request(reference: ClipID(reference), range: range, amount: percent)))
            )
        }
        guard range == nil else { return .failure(ToolError("from and to need reference.")) }
        guard percent != nil || bypass != nil else {
            return .failure(ToolError("Give reference, amount, bypass, or remove."))
        }
        return .success(MatchWork(tracks: ids, mode: .edit(.change(amount: percent, bypassed: bypass))))
    }

    /// The edit of a mode that reads no audio: the amount and the bypass in one edit, or the
    /// remove. One line for each track. A track with no match throws `noMatch` and changes nothing.
    package func edit(_ edit: Edit, _ session: inout Session) throws(SessionError) -> [String] {
        switch edit {
        case .change(let amount, let bypassed):
            if let amount { try session.setMatchAmount(amount, tracks: tracks) }
            if let bypassed { try session.setMatchBypassed(bypassed, tracks: tracks) }
            return lines(matched: Set(tracks), in: session)
        case .remove:
            let had = Set(tracks.filter { session.track($0)?.match != nil })
            try session.removeMatch(tracks: tracks)
            return tracks.map { "\($0): " + (had.contains($0) ? "match removed" : "no match") }
        }
    }

    /// The work in `session`: the stdout lines. A read fault, a refusal, or a cancel keeps
    /// `session` as it was. The flag is read last before the caller saves.
    package func run(
        _ session: inout Session, package: URL, progress: @escaping @Sendable (Double) -> Void = { _ in },
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws(StudioError) -> [String] {
        switch mode {
        case .edit(let kind):
            do throws(SessionError) { return try edit(kind, &session) } catch { throw .session(error) }
        case .set(let request):
            return try set(request, &session, package: package, progress: progress, isCancelled: isCancelled)
        }
    }

    private func set(
        _ request: Request, _ session: inout Session, package: URL, progress: @escaping @Sendable (Double) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws(StudioError) -> [String] {
        let plan = try MatchPlan(
            reference: request.reference, range: request.range, tracks: Set(tracks), in: session)
        let read = try plan.read(of: session, package: package, progress: progress, isCancelled: isCancelled).get()
        #if DEBUG
            // The cancel test: the child says it holds, then waits for the interrupt.
            if ProcessInfo.processInfo.environment["DIRIGIBLE_MATCH_HOLD"] == "1" {
                try? FileHandle.standardError.write(contentsOf: Data("hold\n".utf8))
                while !isCancelled() { usleep(1_000) }
            }
        #endif
        guard !isCancelled() else { throw .matchCancelled }
        let (matched, matches) = try plan.apply(read, amount: request.amount, to: session)
        session = matched
        return lines(matched: Set(matches.keys), in: session)
    }

    /// One line for each named track, from the session after the work: `<track>: match <amount> %
    /// (<boost>, <cut>)` with `, bypassed` after it, as `info` shows it; or `<track>: left out, a
    /// music or effects track` for a track that a match leaves out.
    package func lines(matched: Set<TrackID>, in session: Session) -> [String] {
        tracks.map { id in
            guard matched.contains(id), let match = session.track(id)?.match else {
                return "\(id): left out, a music or effects track"
            }
            return "\(id): " + match.text
        }
    }

    /// The job of a tool call on the files, under the package lock. A match that changes nothing
    /// writes nothing.
    func run(_ package: URL, path: String, control: CallControl) throws(ToolError) -> String {
        do throws(EditFailure<StudioError>) {
            let lines = try editPackageCore(package, ripple: false, writeUnchanged: false, log: control.log) {
                session, _ throws(StudioError) in
                try run(
                    &session, package: package, progress: { control.report($0) },
                    isCancelled: { control.isCancelled() })
            }
            return lines.joined(separator: "\n")
        } catch .body(.matchCancelled) {
            // A cancelled call gets no answer, so no one reads this text.
            throw ToolError(cancelledMessage)
        } catch {
            throw ToolError(error.message(package: path))
        }
    }
}

extension VoiceMatch {
    /// `match <amount> % (<boost>, <cut>)`, with `, bypassed` after it: the largest boost and cut
    /// of the curve at the stored amount, with no loudness offset (`extremes(at:)`). A boost or a
    /// cut of 0 is `0.0 dB`.
    package var text: String {
        let (boost, cut) = extremes(at: amount)
        let dB = { (value: Double) in value == 0 ? "0.0 dB" : String(format: "%+.1f dB", value) }
        return "match \(amount.percent) % (\(dB(boost)), \(dB(cut)))" + (isBypassed ? ", bypassed" : "")
    }
}
