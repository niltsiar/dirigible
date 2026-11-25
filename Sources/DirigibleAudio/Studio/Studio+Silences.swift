import DirigibleCore
import Foundation

/// One silence scan of the Silences tab (decision 0066): the rows, the settings that made them,
/// and the session that Apply checks.
public struct SilenceScan: Equatable, Sendable {
    /// The silences of `LevelSeries.silences` that meet `range`, each with its whole extent.
    public let silences: [Range<Frames>]
    /// The scanned tracks in session order: the tracks that a Mute row lowers.
    public let tracks: [TrackID]
    /// The scanned range, cut to the session end.
    public let range: Range<Frames>
    public let threshold: Gain
    public let minLength: Frames
    /// The levels of the tracks outside the scan over the frames of the scan series, with mute and
    /// solo ignored: the input of `Session.silenceEditWarnings`. Nil when the scan reads all tracks.
    public let outside: LevelSeries?
    /// With no silence, the least threshold that gives one (`LevelSeries.quietestRun`). Nil when
    /// the scan has a silence, or when no run of `minLength` frames fits.
    public let quietest: WindowLevel?
    /// The session that the scan read.
    let scanned: Session

    /// True when `session` has the tracks (IDs, order, gains, clips) and the pool files that the scan
    /// read: the frames of the scan still hold. A marker, a mute, a solo, a name, a role, the
    /// episode, and the transcripts do not count.
    public func isCurrent(in session: Session) -> Bool { sameFrames(session, scanned) }
}

extension Studio {
    /// Tools > Find Silences... (decision 0066): the silences of `tracks` (nil: every track) in
    /// `range` (nil: the whole session), with `checkedMixLevels` and `LevelSeries.silences`,
    /// through `runReadJob` on the `.findingSilences` transport, so the banner and its Cancel show.
    /// When `tracks` leaves out a track, the scan also reads the tracks outside the scan over the
    /// frames of the scan series. The scan changes nothing. A range cut to the session end that is
    /// empty, or an empty `tracks`, reads nothing and gives no row. An unknown track throws
    /// `.session(.unknownTrack)`, a fault of a file of either read `.silencesFaults`, and a cancel
    /// `.silencesCancelled`.
    public func scanSilences(
        tracks: Set<TrackID>?, range: Range<Frames>?, threshold: Gain, minLength: Frames,
        progress: @escaping @MainActor @Sendable (Double) -> Void = { _ in }
    ) async throws(StudioError) -> SilenceScan {
        try checkNotBusy()
        try checkReadable(.export)
        if let unknown = tracks?.first(where: { session.track($0) == nil }) { throw .session(.unknownTrack(unknown)) }
        return try await runReadJob(
            .findingSilences, cancelled: .silencesCancelled, agent: nil, progress: progress,
            read: { session, lock, progress, isCancelled in
                await readSilences(
                    tracks, of: session, lock: lock, range: range, threshold: threshold, minLength: minLength,
                    progress: progress, isCancelled: isCancelled)
            },
            apply: { session, scan in (session, scan) })
    }

    /// Apply of the Silences tab (decision 0066): `Session.editSilences` of `plan`, with the Mute
    /// rows on the scanned tracks, in one edit and one undo entry. The frames of the plan come
    /// from the tracks and the pool files, so a change of a track (its ID, place, gain, or clips)
    /// or of a pool file after the scan throws `.silencesStale`. A marker, a mute, a solo, a name,
    /// a role, the episode, and the transcripts do not count. A plan that removes frames is a ripple
    /// (decision 0037). A throw changes nothing.
    @discardableResult
    public func applySilences(_ plan: SilencePlan, scan: SilenceScan) throws(StudioError) -> SilenceResult {
        guard scan.isCurrent(in: session) else { throw .silencesStale }
        return try edit(ripple: plan.removesFrames(sampleRate: session.sampleRate)) { session throws(SessionError) in
            try session.editSilences(plan, muting: scan.tracks)
        }
    }
}

/// True when the tracks of `a` and `b` have the same IDs in the same order, with the same gains
/// and clips, and the pool files are the same.
private func sameFrames(_ a: Session, _ b: Session) -> Bool {
    a.files == b.files && a.tracks.count == b.tracks.count
        && zip(a.tracks, b.tracks).allSatisfy { $0.id == $1.id && $0.gain == $1.gain && $0.clips == $1.clips }
}

/// The two reads of `scanSilences` off the main actor, in the package that `lock` holds now.
@concurrent nonisolated func readSilences(
    _ tracks: Set<TrackID>?, of session: Session, lock: PackageLock, range: Range<Frames>?, threshold: Gain,
    minLength: Frames, progress: @escaping @Sendable (Double) -> Void, isCancelled: @escaping @Sendable () -> Bool
) async -> Result<SilenceScan, StudioError> {
    dispatchPrecondition(condition: .notOnQueue(.main))
    let whole = Frames.zero..<session.end
    let scope = range?.clamped(to: whole) ?? whole
    let scanned = session.tracks.map(\.id).filter { tracks?.contains($0) ?? true }
    let others = Set(session.tracks.map(\.id)).subtracting(scanned)
    func scan(_ silences: [Range<Frames>], outside: LevelSeries?, quietest: WindowLevel?) -> SilenceScan {
        SilenceScan(
            silences: silences, tracks: scanned, range: scope, threshold: threshold, minLength: minLength,
            outside: outside, quietest: quietest, scanned: session)
    }
    guard !scope.isEmpty, !scanned.isEmpty else { return .success(scan([], outside: nil, quietest: nil)) }
    let package: URL
    do throws(SessionFileError) { package = try lock.package() } catch { return .failure(.file(error)) }
    do throws(CheckedReadError) {
        let series = try checkedMixLevels(
            of: tracks.map { _ in Set(scanned) }, in: session, package: package, range: scope, silence: threshold,
            progress: { progress(others.isEmpty ? $0 : $0 / 2) }, isCancelled: isCancelled)
        let outside =
            others.isEmpty
            ? nil
            : try checkedMixLevels(
                of: others, in: session, package: package, range: series.range, silence: nil,
                progress: { progress(0.5 + $0 / 2) }, isCancelled: isCancelled)
        let silences = series.silences(threshold: threshold, minLength: minLength, in: scope)
        let quietest = silences.isEmpty ? series.quietestRun(minLength: minLength, in: scope) : nil
        return .success(scan(silences, outside: outside, quietest: quietest))
    } catch {
        switch error {
        case .check(let error): return .failure(.silencesRead(error.code.rawValue))
        case .read(let error):
            return .failure(error.code == .ECANCELED ? .silencesCancelled : .silencesRead(error.code.rawValue))
        case .faults(let faults): return .failure(.silencesFaults(faults))
        case .badSource: return .failure(.silencesRead(EINVAL))
        }
    }
}
