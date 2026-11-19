import AVFoundation
import DirigibleCore
import Foundation

/// Why a drift fix stopped with no change (decision 0077 D11).
public enum DriftFailure: Error, Hashable, Sendable {
    /// The measure or the cut scan gave no lag.
    case read(SyncFailure)
    /// The resample or the renames failed.
    case write(ClipRenderError)
    /// The session refused the span or the edit.
    case session(SessionError)
    case cancelled
}

/// Why a sync with the drift option moved the clip by the 0076 lag and wrote no file (decision
/// 0077 D10).
public enum DriftCause: Hashable, Sendable {
    /// The clip is shorter than 5 min.
    case clipTooShort
    /// The clip plays a file with a render origin. Restore Original first.
    case renderedFile
    /// The resample source of the clip has a capture: a take file or a split half of a take.
    case takeFile
    case noFit(DriftFitFailure)
    /// The ratio of the drift link of the played file times the ratio of the fit is 1000 ppm or
    /// more from 1.
    case composedRateOutOfRange
    /// The line changes the lag by less than 1 ms across the clip.
    case underOneMillisecond
}

/// A cut of a drift fix at a pause of the recorder: the clip frame of the cut, and the lag frames
/// that the pause adds.
public struct DriftSplit: Hashable, Sendable {
    public let clipFrame: Frames
    public let pause: Double
}

/// A drift fix that resampled the clip (decision 0077 D12).
public struct DriftFix: Hashable, Sendable {
    /// Lag frames for each clip frame: the clock error of the recording.
    public let slope: Double
    /// The change of the lag across the clip, in frames.
    public let across: Double
    /// The largest distance in frames of an inlier, the first point, or the last point from its line.
    public let worstResidual: Double
    public let splits: [DriftSplit]
    /// The pieces of the clip in time order, and the new file of each piece.
    public let clips: [ClipID]
    public let files: [FileID]
}

public enum DriftOutcome: Hashable, Sendable {
    case corrected(DriftFix)
    case notCorrected(DriftCause)
}

/// The end of a sync with the drift option: the 0076 read, what the move or the fix cut, and the
/// drift outcome.
public struct DriftSyncReport: Hashable, Sendable {
    public let sync: SyncResult
    public let cut: SyncCut
    public let outcome: DriftOutcome
}

/// A clip shorter than this many seconds is not corrected (decision 0077 D10).
private let shortestClipSeconds = 300

/// The one body of a sync with the drift option (decision 0077 D11): `Studio.correctDrift` and the
/// closed-package work of `clip_sync` call it. A clip with a cause of D10 before the measure is
/// read by `syncLag`; else `driftMeasure` gives the 0076 lag and the points, `DriftFit` the line,
/// and `driftCuts` the cuts. A cause moves the clip by the 0076 lag with `Session.sync` and writes
/// no file. Else each piece of `Session.driftPlan` is resampled from its source span with
/// `ClipConversion` at the source rate `rate x ratio` into a temporary WAV, read back, then
/// `Session.correctDrift` edits the session, and only then the WAVs get their names.
///
/// A throw before the renames leaves no new file; a cancel after them removes the new files. A
/// fault of the renames keeps the files that moved. `isCancelled` is read before each block and
/// before and after the renames. It blocks: never call it on the main actor.
package func driftRequest(
    _ clip: ClipID, to track: TrackID, within: Frames?, of session: Session, in package: URL,
    freeBytes: () -> Int64, progress: @escaping (Double) -> Void = { _ in },
    isCancelled: @escaping () -> Bool = { false }
) throws(DriftFailure) -> (session: Session, report: DriftSyncReport, made: [URL]) {
    let span: Range<Frames>
    do throws(SessionError) { span = try session.syncSpan(clip, to: track, within: within) } catch {
        throw .session(error)
    }
    guard let (target, _) = session.clip(clip) else { preconditionFailure("syncSpan checks the clip") }
    guard let played = session.files[target.file] else { throw .session(.unknownFile(target.file)) }
    let rate = session.sampleRate
    func read<Value>(_ body: () throws(SyncFailure) -> Value) throws(DriftFailure) -> Value {
        do throws(SyncFailure) { return try body() } catch {
            if case .cancelled = error { throw .cancelled }
            throw .read(error)
        }
    }
    func moved(by sync: SyncResult, _ cause: DriftCause) throws(DriftFailure) -> (Session, DriftSyncReport, [URL]) {
        var moved = session
        do throws(SessionError) {
            let cut = try moved.sync(clip, by: sync.lag)
            return (moved, DriftSyncReport(sync: sync, cut: cut, outcome: .notCorrected(cause)), [])
        } catch {
            throw .session(error)
        }
    }

    // The source of a drift link is a plain file (D4), so after the origin check each fault of
    // the resample source is a capture.
    let cause: DriftCause? =
        if target.length < Frames(shortestClipSeconds * rate) {
            .clipTooShort
        } else if played.origin != nil {
            .renderedFile
        } else if session.driftSourceFault(of: played.drift?.source ?? played.id) != nil {
            .takeFile
        } else {
            nil
        }
    if let cause {
        let sync = try read { () throws(SyncFailure) in
            try syncLag(
                of: clip, to: track, in: session, package: package, span: span, progress: progress,
                isCancelled: isCancelled)
        }
        return try moved(by: sync, cause)
    }
    let measure = try read { () throws(SyncFailure) in
        try driftMeasure(
            of: clip, to: track, in: session, package: package, span: span, progress: { progress($0 / 2) },
            isCancelled: isCancelled)
    }
    let fit: DriftFit
    do throws(DriftFitFailure) { fit = try DriftFit(points: measure.points, sampleRate: Double(rate)) } catch {
        return try moved(by: measure.sync, .noFit(error))
    }
    let across = fit.slope * Double(target.length.count)
    guard abs(across) * 1000 >= Double(rate) else { return try moved(by: measure.sync, .underOneMillisecond) }
    let cuts = try read { () throws(SyncFailure) in
        try driftCuts(of: clip, to: track, in: session, package: package, fit: fit, isCancelled: isCancelled)
    }
    guard let lines = DriftLines(slope: fit.slope, lags: fit.segments.map(\.offset), cuts: cuts.map { Frames($0) }),
        lines.ratio(after: played.drift) != nil
    else { return try moved(by: measure.sync, .composedRateOutOfRange) }
    let plan: DriftPlan
    do throws(SessionError) { plan = try session.driftPlan(of: clip, lines: lines) } catch { throw .session(error) }

    let (edited, correction, made) = try writeDriftFiles(
        plan, of: session, in: package, freeBytes: freeBytes, progress: { progress(0.5 + $0 / 2) },
        isCancelled: isCancelled,
        edit: { files throws(DriftFailure) in
            var edited = session
            do throws(SessionError) {
                let correction = try edited.correctDrift(clip, lines: lines, files: files)
                return (edited, correction)
            } catch {
                throw .session(error)
            }
        })
    let splits = zip(cuts, zip(fit.segments, fit.segments.dropFirst())).map { cut, pair in
        DriftSplit(clipFrame: Frames(cut), pause: pair.1.offset - pair.0.offset)
    }
    let fix = DriftFix(
        slope: fit.slope, across: across, worstResidual: fit.worstResidual, splits: splits, clips: correction.clips,
        files: correction.files)
    return (edited, DriftSyncReport(sync: measure.sync, cut: correction.cut, outcome: .corrected(fix)), made)
}

/// One WAV for each span of `plan` (decision 0077 D5): the stem "<source stem> drift" by the stem
/// rule of 0040, one space check, `ClipConversion` of the span at the source rate `rate x ratio`
/// with its read-back, then `edit` with the written files, then the renames. Returns what `edit`
/// returned and the renamed files.
private func writeDriftFiles(
    _ plan: DriftPlan, of session: Session, in package: URL, freeBytes: () -> Int64,
    progress: @escaping (Double) -> Void, isCancelled: @escaping () -> Bool,
    edit: ([DriftFile]) throws(DriftFailure) -> (Session, DriftCorrection)
) throws(DriftFailure) -> (Session, DriftCorrection, [URL]) {
    guard let source = session.files[plan.source] else { throw .session(.unknownFile(plan.source)) }
    let url = package.appending(path: "\(clipsFolderName)/\(source.path)")
    guard access(url.path, F_OK) == 0 else {
        let code = errno
        throw .write(
            code == ENOENT ? .sourceMissing(file: source.path) : .sourceUnreadable(file: source.path, errno: code))
    }
    let rate = Double(session.sampleRate)
    let channels = source.layout.channelCount
    let counts = plan.spans.map { ($0.upperBound - $0.lowerBound).count }
    let lengths = counts.map { Int64((Double($0) / plan.ratio.value).rounded(.up)) + 1 }
    var files: NewClipFiles
    do throws(NewClipFault) {
        files = try NewClipFiles(
            in: package, bytes: wavFileBytes(frames: lengths.reduce(0, +), channels: channels), freeBytes: freeBytes)
    } catch {
        throw .write(ClipRenderError(error))
    }
    defer { files.discard() }
    var temporaries: [(stem: String, url: URL)] = []
    for _ in plan.spans {
        let stem = importStems(
            of: URL(filePath: source.path), suffixes: [" drift"], in: session, package: package, taken: files.stems)[0]
        do throws(NewClipFault) { temporaries.append((stem, try files.add(stem: stem))) } catch {
            throw .write(ClipRenderError(error))
        }
    }
    let opened: (descriptor: Int32, file: AVAudioFile)
    do throws(ImportError) { opened = try openAudio(url) } catch {
        throw .write(ClipRenderError(error, source: source.path))
    }
    defer { close(opened.descriptor) }
    let format = opened.file.fileFormat
    guard Int(format.channelCount) == channels, format.sampleRate == rate,
        opened.file.length >= AVAudioFramePosition(plan.spans.map(\.upperBound.count).max() ?? 0)
    else { throw .write(.sourceUnreadable(file: source.path, errno: EIO)) }

    let total = Double(counts.reduce(0, +))
    var done = 0
    var written: [DriftFile] = []
    for (span, (count, temporary)) in zip(plan.spans, zip(counts, temporaries)) {
        guard !isCancelled() else { throw .cancelled }
        let wav = "\(clipsFolderName)/\(temporary.stem).wav"
        let base = Double(done)
        let conversion = ClipConversion(
            package: package, wav: wav, blockFrames: 65_536, readFault: nil,
            unreadable: { .readFailed(file: url.path, errno: $0) }, channels: AVAudioChannelCount(channels),
            progress: { progress((base + $0 * Double(count)) / total) }, isCancelled: isCancelled,
            span: AVAudioFramePosition(span.lowerBound.count)..<AVAudioFramePosition(span.upperBound.count))
        let result: (length: Int, gain: Gain)?
        do throws(FinalizeError) {
            result = try conversion.convert(
                opened.file, file: opened.descriptor, from: rate * plan.ratio.value, to: rate, into: temporary.url)
        } catch {
            if case .readFailed(let file, let code) = error, file == url.path {
                throw .write(.sourceUnreadable(file: source.path, errno: code))
            }
            throw .write(ClipRenderError(error, wav: wav))
        }
        guard let result else {
            throw isCancelled() ? .cancelled : .write(.sourceUnreadable(file: source.path, errno: EIO))
        }
        written.append(DriftFile(stem: temporary.stem, length: Frames(result.length), gain: result.gain))
        done += count
    }
    let (edited, correction) = try edit(written)
    progress(1)
    guard !isCancelled() else { throw .cancelled }
    do throws(NewClipFault) { try files.commit() } catch { throw .write(ClipRenderError(error)) }
    guard !isCancelled() else {
        removeMadeFiles(files.made)
        throw .cancelled
    }
    return (edited, correction, files.made)
}
