import DirigibleAudio
import DirigibleCore

/// The recovery tools of the take banner (decision 0021): the Place rows of the unplaced
/// segments, and the finish of a take without unreadable audio.
extension SessionWindow {
    /// An undo past a take makes its segments unplaced, and a placement clears the redo stack. So
    /// while Redo is available, the rows wait and the banner says that Redo brings the audio back.
    var placeWaitsForRedo: Bool { idleStudio?.canRedo == true }
    var canPlace: Bool { idleStudio != nil && !placeWaitsForRedo }
    var canPlaceAtPlayhead: Bool { canPlace && selectedTrack != nil }

    /// The one selected track of the session, else nil.
    private var selectedTrack: TrackID? {
        // A clip set picks clips, not tracks, so it has no selected track (decision 0038).
        guard let marks = timeline.selection.marks else { return nil }
        let selected = studio?.session.tracks.map(\.id).filter(marks.tracks.contains) ?? []
        return selected.count == 1 ? selected[0] : nil
    }

    /// Places `segment` at its recorded track and time, or at the playhead on the selected track.
    /// A refusal shows the error alert; a segment that ends before the take playhead shows the
    /// alert that it has no clip.
    func place(_ segment: SegmentName, atPlayhead: Bool) async {
        commitDrafts()
        guard canPlace, let studio = idleStudio else { return }
        var (track, start): (TrackID?, Frames?) = (nil, nil)
        if atPlayhead {
            guard let selectedTrack else { return }
            (track, start) = (selectedTrack, studio.playhead)
        }
        do {
            if try await studio.place(segment, on: track, at: start) == nil { alert = .placedWithNoClip(segment) }
        } catch {
            alert = .error(error)
        }
    }

    /// Only an unreadable segment keeps the take pending: another finalize error can go away, so
    /// Retry is the way out.
    var canFinishLeavingUnreadable: Bool {
        guard canRetry, case .finalize(.segmentUnreadable)? = idleStudio?.takeError else { return false }
        return true
    }

    /// Ends the pending take without its unreadable segments; they stay unplaced. A failure keeps
    /// the take pending, and the banner shows it.
    func finishLeavingUnreadable() async {
        commitDrafts()
        guard canFinishLeavingUnreadable else { return }
        try? await idleStudio?.retryFinalize(leavingUnreadable: true)
        await refreshPendingSpace()
    }
}
