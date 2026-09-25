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
}
