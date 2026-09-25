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
