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

    /// "Searches 30 minutes before and after the clip.": the `within` of the sync in whole minutes,
    /// rounded down. Nil when the clip cannot sync.
    func spanLine(in session: Session, text: (L10n) -> String = { $0.text }) -> String? {
        guard let within = try? session.syncWithin(clip) else { return nil }
        return String(format: text(.sheetSyncSpan), within.count / session.sampleRate / 60)
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
/// the spread of the excerpt lags (nil: the drift was not measured), and the head that the move cut.
struct SyncMoved: Equatable {
    /// A spread over this many milliseconds gets its own sentence, as the line of `dirigible clip sync`.
    static let spreadSentenceOver = 20

    let lag: Frames
    let peak: Double
    let spread: Frames?
    let headCut: Frames
    let rate: Int

    /// "Moved the clip 2 min 3.0 s later." (the direction as a word, never a sign), the match score, the
    /// lag change or the not-measured sentence, and the head cut. `text` gives the value of a key.
    func text(text: (L10n) -> String = { $0.text }, locale: Locale = .current) -> String {
        func format(_ key: L10n, _ arguments: any CVarArg...) -> String {
            String(format: text(key), locale: locale, arguments: arguments)
        }
        func duration(_ frames: Frames) -> String {
            let tenths = Int((Double(abs(frames.count)) * 10 / Double(rate)).rounded())
            let (minutes, seconds) = (tenths / 600, Double(tenths % 600) / 10)
            return minutes > 0 ? format(.syncDurationMinutes, minutes, seconds) : format(.syncDurationSeconds, seconds)
        }
        var sentences = [format(lag < .zero ? .bannerSyncEarlier : .bannerSyncLater, duration(lag))]
        sentences.append(format(.bannerSyncMatch, peak))
        if let spread {
            if spread.count * 1000 > Self.spreadSentenceOver * rate {
                let milliseconds = Int((Double(spread.count) * 1000 / Double(rate)).rounded())
                sentences.append(format(.bannerSyncSpread, milliseconds))
            }
        } else {
            sentences.append(format(.bannerSyncNotMeasured))
        }
        if headCut > .zero { sentences.append(format(.bannerSyncHeadCut, duration(headCut))) }
        return sentences.joined(separator: " ")
    }
}

extension SyncMoved {
    init(_ result: SyncResult, headCut: Frames, rate: Int) {
        self.init(lag: result.lag, peak: Double(result.score.peak), spread: result.spread, headCut: headCut, rate: rate)
    }
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
    /// undo entry (decision 0076). A match shows the result banner with Undo, and the view scrolls only
    /// when the new place is out of view. No match shows a banner that changes nothing. The banner Cancel
    /// shows nothing; another error shows the alert.
    func sync(_ draft: SyncDraft) async {
        syncDraft = nil
        syncReport = nil
        guard let studio = idleStudio else { return }
        let session = studio.session
        guard let clip = session.clip(draft.clip)?.clip, let track = session.track(draft.reference) else { return }
        syncPresses += 1
        syncProgress = 0
        defer { syncProgress = nil }
        do throws(StudioError) {
            let (result, headCut) = try await studio.syncClip(draft.clip, to: draft.reference) {
                [weak self] fraction in self?.syncProgress = fraction
            }
            let moved = SyncMoved(result, headCut: headCut, rate: session.sampleRate)
            syncReport = SyncReportShown(
                banner: .syncMoved(moved, revision: studio.sessionRevision, press: syncPresses),
                revision: studio.sessionRevision)
            revealSyncedClip(draft.clip, in: studio)
        } catch .syncCancelled {
            // The banner Cancel: the user asked for it, so no alert.
        } catch .syncNoMatch {
            syncReport = SyncReportShown(
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
