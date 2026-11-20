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
    /// True to also correct the clock drift of the clip (decision 0077).
    let drift: Bool
    let front: Front

    /// What a sync did: the lag, the score, and the drift of the read, and what the move cut. With the
    /// drift option, `outcome` is the fix, or why the drift was not corrected.
    package struct Moved: Sendable {
        let clip: ClipID
        let result: SyncResult
        let cut: SyncCut
        let sampleRate: Int
        var outcome: DriftOutcome?

        /// `moved <clip> by +1.234 s (59232 frames), match 0.98`, or `<clip> is already in sync, match 0.98`
        /// for a lag of 0, which changes nothing; then the drift line (the lag changes by more than 20 ms, or
        /// the drift was not measured and why), then `cut 6.000 s at the head` after a head cut, then
        /// `replaced audio of B, D` with the other clips that the move cut. With the drift option, the
        /// lines of `driftLines` end the text.
        package var lines: [String] {
            let (lag, rate) = (result.lag.count, sampleRate)
            let seconds = String(format: "%.3f", abs(Double(lag)) / Double(rate))
            let match = "match \(String(format: "%.2f", result.score.peak))"
            var lines = [
                lag == 0
                    ? "\(clip) is already in sync, \(match)"
                    : "moved \(clip) by \(lag < 0 ? "-" : "+")\(seconds) s (\(lag) frames), \(match)"
            ]
            switch result.drift {
            case .spread(let spread) where SyncResult.spreadIsNotable(spread, rate: rate):
                lines.append("the lag changes by \(TakeWork.milliseconds(spread.count, rate)) ms across the clip")
            case .spread: break
            case .clipTooShort: lines.append("the drift was not measured: the clip is shorter than 60 s")
            case .onePartMatched: lines.append("the drift was not measured: only one part of the clip matched")
            }
            if cut.head > .zero { lines.append("cut \(TakeWork.seconds(cut.head.count, rate)) s at the head") }
            if !cut.replaced.isEmpty {
                lines.append("replaced audio of \(cut.replaced.map(\.rawValue).joined(separator: ", "))")
            }
            return lines + (outcome.map(driftLines) ?? [])
        }

        /// `corrected a drift of +52.1 ppm (188 ms across the clip) in one resample; the lag stays within
        /// 0.4 ms of the line`, then `split the clip at 31:02.150 (the recording paused 20.000 s)` for each
        /// cut; or `the drift was not corrected: <cause>`.
        private func driftLines(_ outcome: DriftOutcome) -> [String] {
            switch outcome {
            case .notCorrected(let cause): return ["the drift was not corrected: \(cause.text)"]
            case .corrected(let fix):
                let pieces = fix.clips.count == 1 ? "one resample" : "\(fix.clips.count) resamples"
                let fixed =
                    "corrected a drift of \(Self.ppm(fix)) ppm (\(Self.acrossMilliseconds(fix, sampleRate)) ms across "
                    + "the clip) in \(pieces); the lag stays within \(Self.worstMilliseconds(fix, sampleRate)) ms of the line"
                return [fixed]
                    + fix.splits.map { split in
                        let time = TakeWork.milliseconds(split.clipFrame.count, sampleRate)
                        let at = String(format: "%d:%02d.%03d", time / 60_000, time / 1000 % 60, time % 1000)
                        let paused = TakeWork.seconds(Int(split.pause.rounded()), sampleRate)
                        return "split the clip at \(at) (the recording paused \(paused) s)"
                    }
            }
        }

        /// The rate of the clock error with its sign and one decimal, for example `+52.1`.
        private static func ppm(_ fix: DriftFix) -> String { String(format: "%+.1f", fix.slope * 1e6) }

        private static func acrossMilliseconds(_ fix: DriftFix, _ rate: Int) -> Int {
            TakeWork.milliseconds(Int(abs(fix.across).rounded()), rate)
        }

        private static func worstMilliseconds(_ fix: DriftFix, _ rate: Int) -> String {
            String(format: "%.1f", fix.worstResidual * 1000 / Double(rate))
        }

        /// The object of `--json` on one line: `spread` and `headCut` in frames, `spread` null when the
        /// drift was not measured, and `replaced` the IDs of the other clips that the move cut. With the
        /// drift option, `drift_correction` holds `ppm`, `across_ms`, `segments` (the pieces of the clip),
        /// and `worst_ms`; it is null when the drift was not corrected, and `drift_not_corrected` gives
        /// the cause.
        package var json: String {
            // The decimal text keeps `0.98` and `1.234` as they are: a Double would print 0.97999999999999998.
            let seconds = String(format: "%.3f", Double(result.lag.count) / Double(sampleRate))
            let spread: Frames? = if case .spread(let spread) = result.drift { spread } else { nil }
            var object: [String: Any] = [
                "clip": clip.rawValue, "frames": result.lag.count, "seconds": NSDecimalNumber(string: seconds),
                "match": NSDecimalNumber(string: String(format: "%.2f", result.score.peak)),
                "spread": spread.map { $0.count } ?? NSNull(), "headCut": cut.head.count,
                "replaced": cut.replaced.map(\.rawValue),
            ]
            switch outcome {
            case nil: break
            case .corrected(let fix)?:
                object["drift_correction"] = [
                    "ppm": NSDecimalNumber(string: Self.ppm(fix)),
                    "across_ms": Self.acrossMilliseconds(fix, sampleRate), "segments": fix.clips.count,
                    "worst_ms": NSDecimalNumber(string: Self.worstMilliseconds(fix, sampleRate)),
                ]
            case .notCorrected(let cause)?:
                object["drift_correction"] = NSNull()
                object["drift_not_corrected"] = cause.text
            }
            // The object holds only strings, numbers, an array of strings, and null, so the encode does not fail.
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// Checks the arguments: the text of a refusal, for exit 64 or a tool error. `within` is a whole
    /// number of seconds, 1 or more; the session checks the upper end.
    package static func parse(
        clip: String, to track: String, within: Int?, drift: Bool, front: Front
    ) -> Result<SyncWork, ToolError> {
        if let within, within < 1 {
            return .failure(ToolError("\(front.withinName) is a whole number of seconds, 1 or more."))
        }
        return .success(
            SyncWork(clip: ClipID(clip), track: TrackID(track), within: within, drift: drift, front: front))
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
    /// The flag is read last before the caller saves. With the drift option, `driftRequest` also
    /// resamples the clip into new files of `package`, which a cancel removes; `freeBytes` is the
    /// space check of those files.
    package func run(
        _ session: inout Session, package: URL, freeBytes: () -> Int64,
        progress: @escaping @Sendable (Double) -> Void = { _ in },
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws(SyncRefusal) -> Moved {
        let within = try withinFrames(rate: session.sampleRate)
        if drift {
            return try runDrift(
                &session, within: within, package: package, freeBytes: freeBytes, progress: progress,
                isCancelled: isCancelled)
        }
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
        let cut: SyncCut
        do throws(SessionError) { cut = try session.sync(clip, by: result.lag) } catch {
            throw .studio(.session(error))
        }
        return Moved(clip: clip, result: result, cut: cut, sampleRate: session.sampleRate)
    }

    /// The sync with the drift option: `driftRequest` gives the session, the 0076 read, and the outcome.
    private func runDrift(
        _ session: inout Session, within: Frames?, package: URL, freeBytes: () -> Int64,
        progress: @escaping @Sendable (Double) -> Void, isCancelled: @escaping @Sendable () -> Bool
    ) throws(SyncRefusal) -> Moved {
        do throws(DriftFailure) {
            let fixed = try driftRequest(
                clip, to: track, within: within, of: session, in: package, freeBytes: freeBytes, progress: progress,
                isCancelled: isCancelled)
            session = fixed.session
            return Moved(
                clip: clip, result: fixed.report.sync, cut: fixed.report.cut, sampleRate: session.sampleRate,
                outcome: fixed.report.outcome)
        } catch {
            throw refusal(StudioError(error), in: session)
        }
    }

    /// The job of a tool call on the files, under the package lock. A sync that moves nothing writes
    /// nothing. A moved clip with take audio adds the take sync lines (decision 0061).
    func run(_ package: URL, path: String, control: CallControl) throws(ToolError) -> String {
        do throws(EditFailure<SyncRefusal>) {
            let (moved, note) = try editPackageCore(package, ripple: false, writeUnchanged: false, log: control.log) {
                session, lock throws(SyncRefusal) in
                try TakeWork.noted(&session, package: package) { session throws(SyncRefusal) in
                    try run(
                        &session, package: package, freeBytes: { lock.freeBytes() }, progress: { control.report($0) },
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

extension DriftCause {
    /// The text after "the drift was not corrected: " (decision 0077 D10).
    var text: String {
        switch self {
        case .clipTooShort: "the clip is shorter than 5 min"
        case .renderedFile: "the clip plays a rendered file: restore its original audio first"
        case .takeFile: "the clip is audio of a take, which records on the session clock"
        case .noFit(let failure): "no line fits the lags: \(failure.text)"
        case .composedRateOutOfRange:
            "with the earlier correction, the clock would be 1000 ppm or more from the original recording"
        case .underOneMillisecond: "the line changes the lag by less than 1 ms across the clip"
        }
    }
}

extension DriftFitFailure {
    var text: String {
        switch self {
        case .tooFewPoints: "too few parts of the clip matched the track"
        case .twoLines: "the lag jumps between two lines that overlap in time"
        case .tooManyOutliers: "too many parts of the clip are off the line"
        case .endOutlier: "an end of the clip is off the line"
        case .rateOutOfRange: "the clock of the clip is 1000 ppm or more from the track"
        }
    }
}
