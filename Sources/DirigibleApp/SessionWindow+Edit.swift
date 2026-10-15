import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleTimeline

/// The edit commands of the session window (decision 0018). Each command reads the selection once
/// and calls `edit` at most once, so it is one undo entry. During a take `edit` does nothing.
extension SessionWindow {
    /// Copy, Paste, and Delete. With no selection, Copy and Delete do nothing. The clipboard
    /// changes only after a Copy that ran, or a Cut of `runRipple` that ran. On a clip set, Copy
    /// copies the set clips whole, and Delete removes the clips (decision 0038). After a Paste, the
    /// selection is the pasted range, or the pasted clips for a set excerpt.
    func runClipboard(_ command: TimelineCommand, _ studio: Studio) {
        if command == .paste { return paste(insert: false) }
        if command == .copy {
            if let excerpt = try? timeline.selection.excerpt(in: studio.session) { copy(excerpt, of: studio) }
            return
        }
        guard command == .delete else { return }
        let selection = timeline.selection
        let deleted = edit(ripple: false) { session throws(SessionError) -> Bool in
            guard let result = try selection.deleted(session) else { return false }
            session = result
            return true
        }
        if deleted == true, case .clips = selection { timeline.selection = .none }
    }

    /// Cut, Delete and Close Gap, their selected-tracks twins, and Insert (decision 0037). Cut and
    /// Delete and Close Gap ripple the selection out of all tracks, or of the selected tracks for
    /// a twin; the Marks clear and the playhead goes to the start of the range. Cut puts the
    /// selected tracks on the clipboard. Insert moves all tracks right by the clipboard length at
    /// the playhead and pastes there, as Paste does. With no range selection (none or a clip set),
    /// a beep; with an empty range, nothing. Insert with no clipboard does nothing. During a take,
    /// nothing. Under a pending or split take, Studio refuses the ripple (`.rippleBlocked`), and the
    /// window beeps; Insert beeps then also with no clipboard. Cut of a clip set is no ripple
    /// (`cutClips`).
    func runRipple(_ command: TimelineCommand, _ studio: Studio) {
        guard canEdit else { return }
        if command == .insert { return insert(studio) }
        if command == .cut, case .clips = timeline.selection { return cutClips(studio) }
        let selectedOnly = command == .cutSelectedTracks || command == .deleteCloseGapSelectedTracks
        // A ripple needs a range scope (decision 0037), so a clip set beeps (decision 0038).
        guard let marks = timeline.selection.marks else { return beep() }
        guard let scope = marks.rippleScope(selectedOnly: selectedOnly, in: studio.session) else { return }
        let cuts = command == .cut || command == .cutSelectedTracks
        let done = edit(ripple: true) { session throws(SessionError) -> Excerpt? in
            let excerpt = cuts ? try session.excerpt(of: scope.range, on: scope.selected) : nil
            try session.rippleDelete(scope.range, on: scope.tracks)
            return excerpt
        }
        guard let done else { return }
        if let excerpt = done { copy(excerpt, of: studio) }
        timeline.selection = .none
        Task { await studio.perform(.seek(.frame(scope.range.lowerBound))) }
    }

    /// Cut of a clip set (decision 0038): one edit copies the set clips and removes them. The gaps
    /// and the playhead stay. It is no ripple, so a pending or split take does not block it.
    private func cutClips(_ studio: Studio) {
        let selection = timeline.selection
        guard let excerpt = try? selection.excerpt(in: studio.session) else { return }
        let cut = edit(ripple: false) { session throws(SessionError) -> Bool in
            guard let result = try selection.deleted(session) else { return false }
            session = result
            return true
        }
        guard cut == true else { return }
        copy(excerpt, of: studio)
        timeline.selection = .none
    }

    /// Insert: one edit, a ripple insert on all tracks and a paste of the clipboard. Under a pending
    /// or split take, a beep before the paste, so the typed track names stay drafts.
    private func insert(_ studio: Studio) {
        guard studio.canRipple else { return beep() }
        paste(insert: true)
    }

    /// Split and Nudge. A split with no clip at its frames makes no undo entry. Each Nudge press is
    /// one entry; the Marks move with the clips, so the next press moves them again.
    func runSplitOrNudge(_ command: TimelineCommand, _ studio: Studio) {
        if command == .split {
            let points = timeline.selection.splitPoints(playhead: studio.playhead, in: studio.session)
            edit(ripple: false) { session throws(SessionError) in
                try session.splitClips(at: points.frames, on: points.tracks)
            }
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
        guard let move = timeline.selection.nudge(by: offset, in: studio.session) else { return }
        if edit(ripple: false, { session throws(SessionError) in try session.nudge(move.clips, by: move.offset) })
            != nil
        {
            timeline.selection = move.selection
        }
    }

    /// Edit > Fade (decisions 0035 and 0036): the crossfades and the fades of `Selection.faded` in
    /// one edit, so one undo entry. With no change, a beep. During a take `edit` refuses, with no beep.
    func runFade(_ studio: Studio) {
        let selection = timeline.selection
        let changed = edit(ripple: false) { session throws(SessionError) -> Bool in
            guard let result = try selection.faded(session) else { return false }
            session = result
            return true
        }
        if changed == false { NSSound.beep() }
    }

    /// The marker commands. Add names the marker "Marker N" or "Chapter N", N the count of markers
    /// and chapters + 1, and makes it the current marker. Next and Previous seek and set the current
    /// marker. Move and Delete act on the current marker when the session has it, else they beep;
    /// Move with the marker at the playhead beeps too. Marker Info… shows the Marker pane. During a
    /// take they do nothing and do not beep, as no edit command acts then (decision 0018).
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
        case .markerInfo: showMarkerInfo()
        case .moveMarker, .deleteMarker:
            guard canEdit else { return }
            guard var marker = timeline.marker.flatMap({ session.markers[$0] }) else { return beep() }
            switch command {
            case .moveMarker:
                guard marker.position != playhead else { return beep() }
                marker.position = playhead
                edit(ripple: false) { s throws(SessionError) in try s.setMarker(marker) }
            case .deleteMarker:
                if edit(ripple: false, { s throws(SessionError) in try s.removeMarker(marker.id) }) != nil {
                    timeline.marker = nil
                }
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
        if edit(ripple: false, { s throws(SessionError) in try s.setMarker(marker) }) != nil {
            timeline.marker = marker.id
        }
    }
}

extension SessionWindow {
    /// Auto Level and Auto Level per Track (decision 0031): the clips of
    /// `Selection.clipsToLevel(in:)`, or every clip with no selection, in one undo entry. A typed
    /// track name saves first, as at Record: the level makes the name field read-only. Each press
    /// removes the banner of the last level first. With a busy studio, it does nothing else and
    /// shows no alert. A selection with no clip beeps. An error shows the alert, except a cancel
    /// from the banner. A level shows its report in a banner.
    func level(_ mode: LevelMode) async {
        levelReport = nil
        commitDrafts()
        guard let studio = idleStudio else { return }
        let clips =
            timeline.selection.clipsToLevel(in: studio.session)
            ?? Set(studio.session.tracks.flatMap { $0.clips.map(\.id) })
        guard !clips.isEmpty else { return beep() }
        do throws(StudioError) {
            let report = try await studio.level(clips, mode).report
            levelPresses += 1
            levelReport = LevelReportShown(report: report, revision: studio.sessionRevision, press: levelPresses)
        } catch .levelCancelled {
            // The banner Cancel: the user asked for it, so no alert.
        } catch {
            alert = .error(error)
        }
    }

    /// The Cancel of the level banner: it ends the level of the user or of an agent at its next
    /// block, with no gain change (decision 0049).
    func cancelLevel() { studio?.cancelLevel() }

    /// Remove Track: a track of a pending take gives its alert (decision 0012), and a track with
    /// clips asks first (ui-polish A1). The check runs on a copy, so a refused remove asks nothing.
    func removeTracks(_ tracks: [TrackID]) {
        guard !tracks.isEmpty, let studio = idleStudio else { return }
        do throws(SessionError) {
            var copy = studio.session
            try removing(tracks)(&copy)
        } catch {
            alert = .error(.session(error))
            return
        }
        if tracks.contains(where: { studio.session.track($0)?.clips.isEmpty == false }) {
            alert = .confirmRemoveTracks(tracks)
        } else {
            confirmRemoveTracks(tracks)
        }
    }

    /// Removes the tracks in one undo entry, or none: Core checks the IDs again. The name drafts
    /// of the removed tracks go. The armed set stays, so an undo gives back an armed track; every
    /// reader of the set filters it by the session tracks.
    func confirmRemoveTracks(_ tracks: [TrackID]) {
        if edit(ripple: false, removing(tracks)) != nil {
            for track in tracks { drafts[track] = nil }
        }
    }

    /// The Core edit of Remove Track: the check on a copy and the remove run the same edit.
    private func removing(_ tracks: [TrackID]) -> (inout Session) throws(SessionError) -> Void {
        { session throws(SessionError) in
            for track in tracks { try session.removeTrack(track) }
        }
    }

    /// Gives the focus to the lanes and commits the typed track names, in the order of a lane
    /// mouse-down: a focused field takes Esc. A header click and the header handle come here.
    func endNameEdit() {
        focusLanes()
        commitDrafts()
    }

    /// A click on a track header: the rule of `Selection.clickingHeader`. A Control-click shows
    /// the header menu, so it selects nothing here. A click on the header of the renamed track
    /// keeps the rename: the second click of the double-click that started it comes here too.
    func clickHeader(_ track: TrackID, flags: NSEvent.ModifierFlags) {
        guard !flags.contains(.control), renamingTrack != track, let studio else { return }
        endNameEdit()
        timeline.selection = timeline.selection.clickingHeader(
            track, command: flags.contains(.command), shift: flags.contains(.shift), in: studio.session)
    }

    /// Starts the rename of `track`: its name field takes the text focus. During a take the name
    /// is read-only, so it beeps.
    func startRename(_ track: TrackID) {
        guard canEdit else { return beep() }
        renamingTrack = track
        if let row = studio?.session.tracks.firstIndex(where: { $0.id == track }) {
            timelineView?.headers.host.focusName(row: row)
        }
    }

    /// The header menu of `track` shows: a row that is not selected becomes the selection, so the
    /// menu acts on the row that the user sees selected (ui-panel 8).
    func showHeaderMenu(_ track: TrackID) {
        guard let studio, !timeline.selection.headerTracks(in: studio.session).contains(track) else { return }
        clickHeader(track, flags: [])
    }

    /// Remove Track of the header menu: the selected tracks when the row is selected, else the track
    /// of the row.
    func removeFromHeader(_ track: TrackID) {
        guard let studio else { return }
        let selected = timeline.selection.headerTracks(in: studio.session)
        removeTracks(selected.contains(track) ? selected : [track])
    }

    /// Shows in Finder the pool files of `Selection.files`. Only files on disk go; with none, a
    /// beep.
    func showClipsInFinder() async {
        guard let studio else { return }
        let urls = await studio.clipURLs(timeline.selection.files(in: studio.session))
        if urls.isEmpty { NSSound.beep() } else { app?.reveal(urls) }
    }
}

/// The name of a new marker (decision 0018): "Marker N" or "Chapter N", N the count of the markers
/// and chapters + 1. It returns the key and N, because a test process has no app strings.
func newMarkerName(_ kind: Marker.Kind, in session: Session) -> (key: L10n, number: Int) {
    (kind == .chapter ? .chapterDefaultName : .markerDefaultName, session.markers.count + 1)
}

extension AppDelegate {
    /// The title of Tools > Auto Level or Auto Level per Track for the key window: "All" only when
    /// the selection is empty, so the command levels every clip. Nil for another command.
    func levelTitle(_ command: TimelineCommand, for model: SessionWindow?) -> L10n? {
        // The menu asks for each timeline item: skip the scope of the other items.
        guard command == .autoLevel || command == .autoLevelPerTrack else { return nil }
        var all = false
        if let model, let studio = model.studio {
            all = model.timeline.selection.clipsToLevel(in: studio.session) == nil
        }
        switch command {
        case .autoLevel: return all ? .menuToolsLevelAll : .menuToolsLevel
        case .autoLevelPerTrack: return all ? .menuToolsLevelTrackAll : .menuToolsLevelTrack
        default: return nil
        }
    }
}
