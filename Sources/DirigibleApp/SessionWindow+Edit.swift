import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleTimeline

/// The edit commands of the session window (decision 0018). Each command reads the selection once
/// and calls `edit` at most once, so it is one undo entry. During a take `edit` does nothing.
extension SessionWindow {
    /// Copy, Paste, and Delete. With no selection, Copy and Delete do nothing. The clipboard
    /// changes only after a Copy or a Cut that ran.
    func runClipboard(_ command: TimelineCommand, _ studio: Studio) {
        if command == .paste {
            guard let clipboard, let targets = timeline.marks.pasteTracks(for: clipboard, in: studio.session) else {
                return
            }
            // An undo can remove a pool file that the clipboard names (code gate 1).
            let files = studio.session.files
            guard clipboard.lanes.allSatisfy({ $0.clips.allSatisfy { files[$0.file] != nil } }) else {
                NSSound.beep()
                return
            }
            let at = studio.playhead
            if edit({ session throws(SessionError) in try session.paste(clipboard, at: at, on: targets) }) != nil {
                timeline.marks = Marks(inPoint: at, outPoint: at + clipboard.length, tracks: Set(targets))
            }
            return
        }
        guard [.copy, .delete].contains(command), let selection = timeline.marks.selection(in: studio.session)
        else { return }
        if command == .copy {
            clipboard = (try? studio.session.excerpt(of: selection.range, on: selection.tracks)) ?? clipboard
            return
        }
        edit { session throws(SessionError) in
            for track in selection.tracks { try session.clear(selection.range, on: track) }
        }
    }

    /// Cut, Delete and Close Gap, their selected-tracks twins, and Insert (decision 0037). Cut and
    /// Delete and Close Gap ripple the selection out of all tracks, or of the selected tracks for
    /// a twin; the Marks clear and the playhead goes to the start of the range. Cut puts the
    /// selected tracks on the clipboard. Insert moves all tracks right by the clipboard length at
    /// the playhead and pastes there, as Paste does. With no selection or no clipboard, nothing.
    /// During a take, nothing. Under a pending or split take (`rippleBlocked`), a beep.
    func runRipple(_ command: TimelineCommand, _ studio: Studio) {
        guard canEdit else { return }
        if command == .insert { return insert(studio) }
        let selectedOnly = command == .cutSelectedTracks || command == .deleteCloseGapSelectedTracks
        guard let scope = timeline.marks.rippleScope(selectedOnly: selectedOnly, in: studio.session) else { return }
        guard !rippleBlocked(segments: studio.rippleSegments, session: studio.session) else { return beep() }
        let cuts = command == .cut || command == .cutSelectedTracks
        let done = edit { session throws(SessionError) -> Excerpt? in
            let excerpt = cuts ? try session.excerpt(of: scope.range, on: scope.selected) : nil
            try session.rippleDelete(scope.range, on: scope.tracks)
            return excerpt
        }
        guard let done else { return }
        if let excerpt = done { clipboard = excerpt }
        timeline.marks = Marks()
        Task { await studio.perform(.seek(.frame(scope.range.lowerBound))) }
    }

    /// Insert: one edit, a ripple insert on all tracks and a paste of the clipboard.
    private func insert(_ studio: Studio) {
        guard let clipboard, let targets = timeline.marks.pasteTracks(for: clipboard, in: studio.session) else {
            return
        }
        let files = studio.session.files
        guard clipboard.lanes.allSatisfy({ $0.clips.allSatisfy { files[$0.file] != nil } }),
            !rippleBlocked(segments: studio.rippleSegments, session: studio.session)
        else { return beep() }
        let (at, all) = (studio.playhead, studio.session.tracks.map(\.id))
        let inserted = edit { session throws(SessionError) -> Bool in
            try session.rippleInsert(clipboard.length, at: at, on: all)
            try session.paste(clipboard, at: at, on: targets)
            return true
        }
        if inserted == true {
            timeline.marks = Marks(inPoint: at, outPoint: at + clipboard.length, tracks: Set(targets))
        }
    }

    /// Split and Nudge. A split with no clip at its frames makes no undo entry. Each Nudge press is
    /// one entry; the Marks move with the clips, so the next press moves them again.
    func runSplitOrNudge(_ command: TimelineCommand, _ studio: Studio) {
        if command == .split {
            let points = timeline.marks.splitPoints(playhead: studio.playhead, in: studio.session)
            edit { session throws(SessionError) in try session.splitClips(at: points.frames, on: points.tracks) }
            return
        }
        // ponytail: a fixed step of 10 ms, a calibration knob (manual check M3); a zoom step is the
        // upgrade.
        let step = Frames(studio.session.sampleRate / 100)
        let offset: Frames
        switch command {
        case .nudgeLeft: offset = .zero - step
        case .nudgeRight: offset = step
        default: return
        }
        guard let move = timeline.marks.nudge(by: offset, in: studio.session) else { return }
        if edit({ session throws(SessionError) in try session.nudge(move.clips, by: move.offset) }) != nil {
            timeline.marks = move.marks
        }
    }

    /// Edit > Fade (decisions 0035 and 0036): the crossfades and the fades of `Marks.faded` in one
    /// edit, so one undo entry. With no change, a beep. During a take `edit` refuses, with no beep.
    func runFade(_ studio: Studio) {
        let marks = timeline.marks
        let changed = edit { session throws(SessionError) -> Bool in
            guard let result = try marks.faded(session) else { return false }
            session = result
            return true
        }
        if changed == false { NSSound.beep() }
    }

    /// The marker commands. Add names the marker "Marker N" or "Chapter N", N the count of markers
    /// and chapters + 1, and makes it the current marker. Next and Previous seek and set the current
    /// marker. Rename, Move, and Delete act on the current marker when the session has it.
    func runMarker(_ command: TimelineCommand, _ studio: Studio) {
        let (session, playhead) = (studio.session, studio.playhead)
        switch command {
        case .addMarker, .addChapter: addMarker(command == .addChapter ? .chapter : .marker, at: playhead)
        case .previousMarker, .nextMarker:
            let found =
                command == .nextMarker
                ? session.markerPosition(after: playhead) : session.markerPosition(before: studio.previousFrom)
            guard let frame = found else { return }
            // At one position: a marker before a chapter, then by ID.
            timeline.marker =
                session.markers.values.filter { $0.position == frame }
                .min { ($0.kind == .chapter ? 1 : 0, $0.id) < ($1.kind == .chapter ? 1 : 0, $1.id) }?.id
            Task { await studio.perform(.seek(.frame(frame))) }
        case .renameMarker, .moveMarker, .deleteMarker:
            guard var marker = timeline.marker.flatMap({ session.markers[$0] }) else { return }
            switch command {
            // During a take the alert does not open, as no edit command acts then (decision 0018).
            case .renameMarker where canEdit: timeline.renaming = MarkerRename(id: marker.id, name: marker.name)
            case .moveMarker:
                marker.position = playhead
                edit { s throws(SessionError) in try s.setMarker(marker) }
            case .deleteMarker:
                if edit({ s throws(SessionError) in try s.removeMarker(marker.id) }) != nil { timeline.marker = nil }
            default: return
            }
        default: return
        }
    }

    /// Adds a marker or a chapter at `frame` in one undo entry and makes it the current marker: the
    /// Markers menu adds at the playhead, the ruler menu at the clicked frame (mouse-edits Q8).
    func addMarker(_ kind: Marker.Kind, at frame: Frames) {
        guard let studio else { return }
        let name = newMarkerName(kind, in: studio.session)
        let marker = Marker(id: MarkerID(), name: name.key.format(name.number), position: frame, kind: kind)
        if edit({ s throws(SessionError) in try s.setMarker(marker) }) != nil { timeline.marker = marker.id }
    }

    /// OK of the rename alert: saves the name of its marker, when the session still has it. When a
    /// take started while the alert was open, OK saves nothing and the typed name stays in the
    /// alert state, so the alert shows it again until the user presses OK after the take or Cancel.
    func commitRename() {
        guard let renaming = timeline.renaming, canEdit else { return }
        timeline.renaming = nil
        guard var marker = studio?.session.markers[renaming.id] else { return }
        marker.name = renaming.name
        edit { s throws(SessionError) in try s.setMarker(marker) }
    }
}

extension SessionWindow {
    /// Auto Level and Auto Level per Track (decision 0031): each whole clip that the selection
    /// touches, in one undo entry. A typed track name saves first, as at Record: the level makes
    /// the name field read-only. With no selection or a busy studio, it does nothing and shows no
    /// alert. An error shows the alert.
    func level(_ mode: LevelMode) async {
        commitNames()
        guard let studio = idleStudio, let clips = timeline.marks.clipsToLevel(in: studio.session) else { return }
        do throws(StudioError) { try await studio.level(clips, mode) } catch { alert = .error(error) }
    }

    /// Removes the tracks in one undo entry, or none: a track of a pending take gives its alert
    /// (decision 0012). The name drafts of the removed tracks go. The armed set stays, so an undo
    /// gives back an armed track; every reader of the set filters it by the session tracks.
    func removeTracks(_ tracks: [TrackID]) {
        guard !tracks.isEmpty else { return }
        if edit({ s throws(SessionError) -> Void in for track in tracks { try s.removeTrack(track) } }) != nil {
            for track in tracks { drafts[track] = nil }
        }
    }

    /// Shows in Finder the pool files of the clips that overlap the selection on its tracks, or of
    /// every clip with no selection. Only files on disk go; with none, a beep.
    func showClipsInFinder() async {
        guard let studio else { return }
        let session = studio.session
        let selection = timeline.marks.selection(in: session)
        let tracks = selection?.tracks.compactMap(session.track) ?? session.tracks
        let files = tracks.flatMap { track in
            track.clips.filter { clip in selection.map { clip.range.overlaps($0.range) } ?? true }.map(\.file)
        }
        let urls = await studio.clipURLs(Set(files))
        if urls.isEmpty { NSSound.beep() } else { app?.reveal(urls) }
    }
}

/// The name of a new marker (decision 0018): "Marker N" or "Chapter N", N the count of the markers
/// and chapters + 1. It returns the key and N, because a test process has no app strings.
func newMarkerName(_ kind: Marker.Kind, in session: Session) -> (key: L10n, number: Int) {
    (kind == .chapter ? .chapterDefaultName : .markerDefaultName, session.markers.count + 1)
}
