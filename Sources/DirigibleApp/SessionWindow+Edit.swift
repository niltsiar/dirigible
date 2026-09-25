import DirigibleAudio
import DirigibleCore

/// The edit commands of the session window (decision 0018). Each command reads the selection once
/// and calls `edit` at most once, so it is one undo entry. During a take `edit` does nothing.
extension SessionWindow {
    /// Cut, Copy, Paste, and Delete. With no selection, Cut, Copy, and Delete do nothing. The
    /// clipboard changes only after a Copy or a Cut that ran.
    func runClipboard(_ command: TimelineCommand, _ studio: Studio) {
        if command == .paste {
            guard let clipboard, let targets = timeline.marks.pasteTracks(for: clipboard, in: studio.session) else {
                return
            }
            let at = studio.playhead
            if edit({ session throws(SessionError) in try session.paste(clipboard, at: at, on: targets) }) != nil {
                timeline.marks = Marks(inPoint: at, outPoint: at + clipboard.length, tracks: Set(targets))
            }
            return
        }
        guard let selection = timeline.marks.selection(in: studio.session) else { return }
        if command == .copy {
            clipboard = (try? studio.session.excerpt(of: selection.range, on: selection.tracks)) ?? clipboard
            return
        }
        let excerpt = edit { session throws(SessionError) in
            let excerpt = try session.excerpt(of: selection.range, on: selection.tracks)
            for track in selection.tracks { try session.clear(selection.range, on: track) }
            return excerpt
        }
        if command == .cut, let excerpt { clipboard = excerpt }
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
        guard let move = timeline.marks.nudge(by: command == .nudgeLeft ? .zero - step : step, in: studio.session)
        else { return }
        if edit({ session throws(SessionError) in try session.nudge(move.clips, by: move.offset) }) != nil {
            timeline.marks = move.marks
        }
    }

    /// The marker commands. Add names the marker "Marker N" or "Chapter N", N the count of markers
    /// and chapters + 1, and makes it the current marker. Next and Previous seek and set the current
    /// marker. Rename, Move, and Delete act on the current marker when the session has it.
    func runMarker(_ command: TimelineCommand, _ studio: Studio) {
        let (session, playhead) = (studio.session, studio.playhead)
        switch command {
        case .addMarker, .addChapter:
            let kind: Marker.Kind = command == .addChapter ? .chapter : .marker
            let name = newMarkerName(kind, in: session)
            let marker = Marker(id: MarkerID(), name: name.key.format(name.number), position: playhead, kind: kind)
            if edit({ s throws(SessionError) in try s.setMarker(marker) }) != nil { timeline.marker = marker.id }
        case .previousMarker, .nextMarker:
            let found =
                command == .nextMarker
                ? session.markerPosition(after: playhead) : session.markerPosition(before: playhead)
            guard let frame = found else { return }
            // At one position: a marker before a chapter, then by ID.
            timeline.marker =
                session.markers.values.filter { $0.position == frame }
                .min { ($0.kind == .chapter ? 1 : 0, $0.id) < ($1.kind == .chapter ? 1 : 0, $1.id) }?.id
            Task { await studio.perform(.seek(.frame(frame))) }
        default:
            guard var marker = timeline.marker.flatMap({ session.markers[$0] }) else { return }
            switch command {
            case .renameMarker: timeline.renaming = MarkerRename(id: marker.id, name: marker.name)
            case .moveMarker:
                marker.position = playhead
                edit { s throws(SessionError) in try s.setMarker(marker) }
            default:
                if edit({ s throws(SessionError) in try s.removeMarker(marker.id) }) != nil { timeline.marker = nil }
            }
        }
    }

    /// OK of the rename alert: saves the name of its marker, when the session still has it.
    func commitRename() {
        guard let renaming = timeline.renaming else { return }
        timeline.renaming = nil
        guard var marker = studio?.session.markers[renaming.id] else { return }
        marker.name = renaming.name
        edit { s throws(SessionError) in try s.setMarker(marker) }
    }
}

/// The name of a new marker (decision 0018): "Marker N" or "Chapter N", N the count of the markers
/// and chapters + 1. It returns the key and N, because a test process has no app strings.
func newMarkerName(_ kind: Marker.Kind, in session: Session) -> (key: L10n, number: Int) {
    (kind == .chapter ? .chapterDefaultName : .markerDefaultName, session.markers.count + 1)
}
