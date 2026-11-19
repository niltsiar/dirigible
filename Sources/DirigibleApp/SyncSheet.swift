import DirigibleAudio
import DirigibleCore
import DirigibleTimeline
import SwiftUI

/// The values of the Sync Clip to Track sheet (decision 0076): the clip and its reference track. The
/// sheet has no search field: the sync from the app searches `Session.defaultSyncWithin` on each side
/// of the clip, cut as `Session.syncWithin` says.
struct SyncDraft: Equatable {
    /// A track of the popup: its ID and its row text, "Guest (Dialogue)", or the name alone with no role.
    struct Row: Equatable {
        let id: TrackID
        let text: String
    }

    let clip: ClipID
    var reference: TrackID

    /// The sheet for `clip`, on the track of `Session.defaultSyncReference(for:)`. Nil when that is nil:
    /// no other track has a clip near the clip, so the popup would be empty.
    init?(clip: ClipID, in session: Session) {
        guard let reference = session.defaultSyncReference(for: clip) else { return nil }
        (self.clip, self.reference) = (clip, reference)
    }

    /// Each track but the track of the clip, in session order. `text` gives the value of a key.
    func rows(in session: Session, text: (L10n) -> String = { $0.text }) -> [Row] {
        let home = session.clip(clip)?.track
        return session.tracks.filter { $0.id != home }.map { track in
            guard let role = track.role else { return Row(id: track.id, text: track.name) }
            return Row(id: track.id, text: String(format: text(.sheetSyncRow), track.name, text(role.title)))
        }
    }

    /// The `syncSpanText` of the `within` that the sync uses. Nil when the clip cannot sync.
    func spanLine(in session: Session, locale: Locale = .current, text: (L10n) -> String = { $0.text }) -> String? {
        guard let within = try? session.syncWithin(clip) else { return nil }
        return syncSpanText(within: within, rate: session.sampleRate, locale: locale, text: text)
    }

    /// The line for a session with no track on an app route, where the default reference is the first
    /// track with audio; nil with one.
    func noCallLine(in session: Session, text: (L10n) -> String = { $0.text }) -> String? {
        let call = session.tracks.contains { if case .app = $0.route { true } else { false } }
        return call ? nil : text(.sheetSyncNoCall)
    }

    /// The reason that Sync is off, as `Session.syncSpan` refuses the reference, or nil.
    func refusal(in session: Session) -> SessionError? {
        do throws(SessionError) {
            _ = try session.syncSpan(clip, to: reference)
            return nil
        } catch {
            return error
        }
    }
}

/// The first frame of `range` when no frame of it is in the `visibleFrames` from `origin`, else nil: the
/// view of a sync scrolls only when the clip leaves it (decision 0076).
func syncRevealFrame(of range: Range<Frames>, origin: Double, visibleFrames: Double) -> Frames? {
    let (first, end) = (Double(range.lowerBound.count), Double(range.upperBound.count))
    return end <= origin || first >= origin + visibleFrames ? range.lowerBound : nil
}

/// What a sync did, for its result banner (decision 0076): the lag with its direction, the match score,
/// the spread of the excerpt lags or why the drift was not measured, the head that the move cut, and
/// the names of the other clips that it cut.
struct SyncMoved: Equatable {
    let lag: Frames
    let peak: Double
    let drift: SyncDrift
    let headCut: Frames
    let replaced: [String]
    let rate: Int

    /// "Moved the clip 2 min 3.0 s later." (the direction as a word, never a sign), or "The clip is
    /// already in sync." for lag 0, the match score, the lag change or the not-measured sentence with its
    /// cause, the head cut, and the other clips that the move cut. `text` gives the value of a key.
    func text(text: (L10n) -> String = { $0.text }, locale: Locale = .current) -> String {
        func format(_ key: L10n, _ arguments: any CVarArg...) -> String {
            String(format: text(key), locale: locale, arguments: arguments)
        }
        func duration(_ frames: Frames) -> String {
            let tenths = Int((Double(abs(frames.count)) * 10 / Double(rate)).rounded())
            let (minutes, seconds) = (tenths / 600, Double(tenths % 600) / 10)
            return minutes > 0 ? format(.syncDurationMinutes, minutes, seconds) : format(.syncDurationSeconds, seconds)
        }
        var sentences = [
            lag == .zero
                ? format(.bannerSyncAlready)
                : format(lag < .zero ? .bannerSyncEarlier : .bannerSyncLater, duration(lag))
        ]
        sentences.append(format(.bannerSyncMatch, peak))
        switch drift {
        case .spread(let spread) where SyncResult.spreadIsNotable(spread, rate: rate):
            let milliseconds = Int((Double(spread.count) * 1000 / Double(rate)).rounded())
            sentences.append(format(.bannerSyncSpread, milliseconds))
        case .spread: break
        case .clipTooShort: sentences.append(format(.bannerSyncTooShort))
        case .onePartMatched: sentences.append(format(.bannerSyncNotMeasured))
        }
        if headCut > .zero { sentences.append(format(.bannerSyncHeadCut, duration(headCut))) }
        if !replaced.isEmpty {
            sentences.append(format(.bannerSyncReplaced, replaced.formatted(.list(type: .and).locale(locale))))
        }
        return sentences.joined(separator: " ")
    }
}

extension SyncMoved {
    /// The banner of `result` and `cut`, with the names of the cut clips in `before`, the session before
    /// the move: the move can remove a clip.
    init(_ result: SyncResult, cut: SyncCut, before: Session) {
        let names = cut.replaced.map { id in before.clip(id).map { before.name(of: $0.clip) } ?? id.rawValue }
        self.init(
            lag: result.lag, peak: Double(result.score.peak), drift: result.drift, headCut: cut.head, replaced: names,
            rate: before.sampleRate)
    }
}

/// "Searches 30 minutes before and after the clip.": `within` in whole minutes, or in whole seconds
/// under 1 minute, rounded down. No plural form (0010); Foundation gives the unit.
func syncSpanText(within: Frames, rate: Int, locale: Locale, text: (L10n) -> String = { $0.text }) -> String {
    let seconds = within.count / rate
    let (span, unit): (Duration, Duration.UnitsFormatStyle.Unit) =
        seconds < 60 ? (.seconds(seconds), .seconds) : (.seconds(seconds / 60 * 60), .minutes)
    let style = Duration.UnitsFormatStyle(allowedUnits: [unit], width: .wide).locale(locale)
    return String(format: text(.sheetSyncSpan), locale: locale, span.formatted(style))
}

/// "No match: <clip> was not found on <track>.", with the lane label of the clip.
func syncNoMatchText(clip: String, track: String, text: (L10n) -> String = { $0.text }) -> String {
    String(format: text(.bannerSyncNoMatch), clip, track)
}

extension Selection {
    /// The clip of a clip set of one clip. A range, a set of two or more, and no selection give nil.
    func syncClip(in session: Session) -> ClipID? {
        guard case .clips = self else { return nil }
        let clips = selectedClips(in: session)
        return clips.count == 1 ? clips[0].clip.id : nil
    }
}

/// Tools > Sync Clip to Track... (decision 0076): the reference track popup with each role, the span
/// line, and the no-call-track line. Sync is off with the reason while the reference has no clip near
/// the clip. Cancel takes Esc, and Sync takes Return.
struct SyncSheet: View {
    let model: SessionWindow
    let studio: Studio
    @State private var draft: SyncDraft

    init(model: SessionWindow, studio: Studio, draft: SyncDraft) {
        (self.model, self.studio) = (model, studio)
        _draft = State(initialValue: draft)
    }

    var body: some View {
        let session = studio.session
        let refusal = draft.refusal(in: session)
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.sheetSyncTitle.key).font(.headline)
            Picker(L10n.sheetSyncReference.key, selection: $draft.reference) {
                ForEach(draft.rows(in: session), id: \.id) { row in Text(verbatim: row.text).tag(row.id) }
            }
            if let line = draft.spanLine(in: session) { Text(verbatim: line).foregroundStyle(.secondary) }
            if let line = draft.noCallLine(in: session) { Text(verbatim: line).foregroundStyle(.secondary) }
            if let refusal {
                Label {
                    Text(verbatim: L10n.message(for: .session(refusal), session: session))
                } icon: {
                    Image(systemName: WindowBanner.Kind.warning.symbol).foregroundStyle(.orange)
                }
            }
            HStack {
                Spacer()
                Button(L10n.alertCancel.key) { model.syncDraft = nil }.keyboardShortcut(.cancelAction)
                Button(L10n.sheetSyncApply.key) { Task { await model.sync(draft) } }
                    .keyboardShortcut(.defaultAction).disabled(refusal != nil)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

extension SessionWindow {
    /// The clip that Sync Clip to Track acts on: the clip of a one-clip selection, with another track that
    /// holds a clip in the default span, while the window takes edits and no dialog or import runs.
    var syncTarget: ClipID? {
        guard !dialogShowing, importJob == nil, let studio = idleStudio,
            let clip = timeline.selection.syncClip(in: studio.session),
            studio.session.defaultSyncReference(for: clip) != nil
        else { return nil }
        return clip
    }

    /// Tools > Sync Clip to Track...: opens the sheet for the selected clip. A typed track name saves first.
    func startSync() {
        commitDrafts()
        if let clip = syncTarget { openSyncSheet(for: clip) }
    }

    /// The Choose Another Track button of the no-match banner: the sheet again for `clip`.
    func chooseAnotherSyncTrack(for clip: ClipID) { openSyncSheet(for: clip) }

    func canChooseAnotherSyncTrack(for clip: ClipID) -> Bool {
        !dialogShowing && importJob == nil
            && idleStudio.map { SyncDraft(clip: clip, in: $0.session) != nil } == true
    }

    private func openSyncSheet(for clip: ClipID) {
        guard canChooseAnotherSyncTrack(for: clip), let studio = idleStudio else { return }
        syncDraft = SyncDraft(clip: clip, in: studio.session)
    }

    /// Sync of the sheet: moves the clip to the audio that it shares with the reference track, in one
    /// undo entry (decision 0076). A match shows the result banner, with Undo only when the clip moved,
    /// and the view scrolls only when the new place is out of view. No match shows a banner that changes
    /// nothing. The banner Cancel shows nothing; another error shows the alert.
    func sync(_ draft: SyncDraft) async {
        syncDraft = nil
        syncReport = nil
        guard let studio = idleStudio else { return }
        let session = studio.session
        guard let clip = session.clip(draft.clip)?.clip, let track = session.track(draft.reference) else { return }
        syncPresses += 1
        syncProgress = 0
        defer { syncProgress = nil }
        let before = studio.sessionRevision
        do throws(StudioError) {
            let (result, cut) = try await studio.syncClip(draft.clip, to: draft.reference) {
                [weak self] fraction in self?.syncProgress = fraction
            }
            let moved = SyncMoved(result, cut: cut, before: session)
            let revision = studio.sessionRevision
            syncReport = ToolBannerShown(
                banner: .syncMoved(moved, revision: revision == before ? nil : revision, press: syncPresses),
                revision: revision)
            revealSyncedClip(draft.clip, in: studio)
        } catch .syncCancelled {
            // The banner Cancel: the user asked for it, so no alert.
        } catch .syncNoMatch {
            syncReport = ToolBannerShown(
                banner: .syncNoMatch(
                    clip: draft.clip, clipName: session.name(of: clip), trackName: track.name, press: syncPresses),
                revision: studio.sessionRevision)
        } catch {
            alert = .error(error)
        }
    }

    /// Scrolls to the start of the moved clip when no frame of it is in view.
    private func revealSyncedClip(_ id: ClipID, in studio: Studio) {
        guard let view = timelineView, let (clip, track) = studio.session.clip(id),
            let lane = studio.session.tracks.firstIndex(where: { $0.id == track }),
            let frame = syncRevealFrame(of: clip.range, origin: view.origin, visibleFrames: view.visibleFrames)
        else { return }
        view.reveal(frame: frame, lane: lane)
    }
}
