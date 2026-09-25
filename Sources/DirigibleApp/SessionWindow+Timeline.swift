import DirigibleAudio
import DirigibleCore

/// The timeline side of the session window (decision 0017).
extension SessionWindow {
    /// The narrowed record-over warning of the transport bar (decisions 0016, 0017): Record can
    /// start, and an armed track has a clip at the playhead that is not in view.
    var showsRecordOver: Bool {
        guard canRecord, let studio else { return false }
        return recordOverHidden(
            session: studio.session, armed: armed, playhead: studio.playhead, visible: timeline.visible)
    }
}

extension SessionWindow {
    /// A click in a lane, under 3 pt of movement (decision 0017): Shift selects from the playhead
    /// to the click and the lane joins; Command toggles the lane; a plain click empties the Marks
    /// and seeks.
    func timelineClick(at frame: Frames, lane: Int, shift: Bool, command: Bool) {
        guard let studio, studio.session.tracks.indices.contains(lane) else { return }
        let track = studio.session.tracks[lane].id
        if shift {
            timeline.marks = timeline.marks.extended(to: frame, lane: track, playhead: studio.playhead)
        } else if command {
            timeline.marks = timeline.marks.toggled(track)
        } else {
            timeline.marks = Marks()
            Task { await studio.perform(.seek(.frame(frame))) }
        }
    }

    /// A drag in the lanes: the range from the mouse-down frame to the pointer, on the lanes that
    /// the drag spans.
    func timelineDrag(from: Frames, to: Frames, lanes: (Int, Int)) {
        guard let studio else { return }
        timeline.marks = Marks.drag(from: from, to: to, lanes: lanes, in: studio.session)
    }

    /// A click on the ruler seeks. The Marks do not change.
    func rulerClick(at frame: Frames) {
        guard let studio else { return }
        Task { await studio.perform(.seek(.frame(frame))) }
    }
}
