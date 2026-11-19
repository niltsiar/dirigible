import DirigibleAudio
import DirigibleCore
import Foundation

/// Why a sync changes nothing: an argument that only the session can check, or a refusal of the
/// studio (decision 0076).
package enum SyncRefusal: Error {
    /// A bad argument, with its text: exit 64.
    case argument(String)
    case studio(StudioError)

    package func message(package: String) -> String {
        switch self {
        case .argument(let text): text
        case .studio(let error): error.message(package: package)
        }
    }
}

/// The work of a `clip_sync` call or a `dirigible clip sync` command after its arguments are checked
/// (decisions 0049 and 0076). It is the one owner of the argument rules, the steps on the files, and
/// the texts of the command and the tool. In the app, `liveJob` runs `Studio.syncClip`.
package struct SyncWork: Sendable {
    /// The front end of a call: each one spells the `within` argument its own way.
    package enum Front: Sendable {
        case commandLine, tool

        var withinName: String { self == .commandLine ? "--within" : "within" }
    }

    let clip: ClipID
    let track: TrackID
    /// The search distance on each side of the clip in whole seconds, or nil for the default.
    let within: Int?
    let front: Front

    /// What a sync did: the lag, the score, and the spread of the read, and the head that the move cut.
    package struct Moved: Sendable {
        let clip: ClipID
        let result: SyncResult
        let headCut: Frames
        let sampleRate: Int

        /// `moved <clip> by +1.234 s (59232 frames), match 0.98`, then the drift line (the lag changes by
        /// more than 20 ms, or the drift was not measured and why), then `cut 6.000 s at the head` after a
        /// head cut.
        package var lines: [String] {
            let (lag, rate) = (result.lag.count, sampleRate)
            let seconds = String(format: "%.3f", abs(Double(lag)) / Double(rate))
            var lines = [
                "moved \(clip) by \(lag < 0 ? "-" : "+")\(seconds) s (\(lag) frames), "
                    + "match \(String(format: "%.2f", result.score.peak))"
            ]
            switch result.drift {
            case .spread(let spread) where SyncResult.spreadIsNotable(spread, rate: rate):
                lines.append("the lag changes by \(TakeWork.milliseconds(spread.count, rate)) ms across the clip")
            case .spread: break
            case .clipTooShort: lines.append("the drift was not measured: the clip is shorter than 60 s")
            case .onePartMatched: lines.append("the drift was not measured: only one part of the clip matched")
            }
            if headCut > .zero { lines.append("cut \(TakeWork.seconds(headCut.count, rate)) s at the head") }
            return lines
        }

        /// The object of `--json` on one line: `spread` and `headCut` in frames, and `spread` null when
        /// the drift was not measured.
        package var json: String {
            // The decimal text keeps `0.98` and `1.234` as they are: a Double would print 0.97999999999999998.
            let seconds = String(format: "%.3f", Double(result.lag.count) / Double(sampleRate))
            let spread: Frames? = if case .spread(let spread) = result.drift { spread } else { nil }
            let object: [String: Any] = [
                "clip": clip.rawValue, "frames": result.lag.count, "seconds": NSDecimalNumber(string: seconds),
                "match": NSDecimalNumber(string: String(format: "%.2f", result.score.peak)),
                "spread": spread.map { $0.count } ?? NSNull(), "headCut": headCut.count,
            ]
            // The object holds only strings, numbers, and null, so the encode does not fail.
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// Checks the arguments: the text of a refusal, for exit 64 or a tool error. `within` is a whole
    /// number of seconds, 1 or more; the session checks the upper end.
    package static func parse(clip: String, to track: String, within: Int?, front: Front) -> Result<SyncWork, ToolError>
    {
        if let within, within < 1 {
            return .failure(ToolError("\(front.withinName) is a whole number of seconds, 1 or more."))
        }
        return .success(SyncWork(clip: ClipID(clip), track: TrackID(track), within: within, front: front))
    }

    /// `within` in frames at `rate`, or nil for the default. A value over 2^40 frames is a bad argument.
    func withinFrames(rate: Int) throws(SyncRefusal) -> Frames? {
        guard let within else { return nil }
        let most = Frames.limit.count / rate
        guard within <= most else {
            throw .argument("\(front.withinName) is over 2^40 frames at \(rate) Hz: give \(most) seconds or less.")
        }
        return Frames(within * rate)
    }

    /// The refusal for `error` of a sync in `session`, with the `within` spelling of the front end. The
    /// cap of the search span is in seconds of the rate of the session, and the largest `within` is that
    /// of the clip. A largest `within` under 1 s fits no whole second, but the default fits.
    func refusal(_ error: StudioError, in session: Session) -> SyncRefusal {
        guard case .session(.syncSpanTooLong(let largest)) = error else { return .studio(error) }
        let (rate, cap, name) = (session.sampleRate, session.syncSpanCap, front.withinName)
        guard let found = session.clip(clip)?.clip, found.length <= cap else {
            return .argument(SessionError.syncSpanTooLong(maxWithin: .zero).message)
        }
        let over = "The search span is over \(cap.count / rate) s"
        guard largest.count >= rate else {
            return .argument(
                "\(over), and the largest \(name) for this clip is under 1 s. "
                    + "Leave out \(name): the sync then searches the largest span that fits.")
        }
        return .argument("\(over). Use \(name) \(largest.count / rate) or less for this clip.")
    }

    /// The sync in `session`. A refusal, a read fault, no match, or a cancel keeps `session` as it was.
    /// The flag is read last before the caller saves.
    package func run(
        _ session: inout Session, package: URL, progress: @escaping @Sendable (Double) -> Void = { _ in },
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws(SyncRefusal) -> Moved {
        let within = try withinFrames(rate: session.sampleRate)
        let span: Range<Frames>
        do throws(SessionError) { span = try session.syncSpan(clip, to: track, within: within) } catch {
            throw refusal(.session(error), in: session)
        }
        let result: SyncResult
        do throws(SyncFailure) {
            result = try syncLag(
                of: clip, to: track, in: session, package: package, span: span, progress: progress,
                isCancelled: isCancelled)
        } catch {
            throw .studio(StudioError(error))
        }
        guard !isCancelled() else { throw .studio(.syncCancelled) }
        let cut: Frames
        do throws(SessionError) { cut = try session.sync(clip, by: result.lag) } catch {
            throw .studio(.session(error))
        }
        return Moved(clip: clip, result: result, headCut: cut, sampleRate: session.sampleRate)
    }

    /// The job of a tool call on the files, under the package lock. A sync that moves nothing writes
    /// nothing. A moved clip with take audio adds the take sync lines (decision 0061).
    func run(_ package: URL, path: String, control: CallControl) throws(ToolError) -> String {
        do throws(EditFailure<SyncRefusal>) {
            let (moved, note) = try editPackageCore(package, ripple: false, writeUnchanged: false, log: control.log) {
                session, _ throws(SyncRefusal) in
                try TakeWork.noted(&session, package: package) { session throws(SyncRefusal) in
                    try run(
                        &session, package: package, progress: { control.report($0) },
                        isCancelled: { control.isCancelled() })
                }
            }
            return (moved.lines + note).joined(separator: "\n")
        } catch .body(.studio(.syncCancelled)) {
            // A cancelled call gets no answer, so no one reads this text.
            throw ToolError(cancelledMessage)
        } catch {
            throw ToolError(error.message(package: path))
        }
    }
}
