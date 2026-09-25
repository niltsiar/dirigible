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
}
