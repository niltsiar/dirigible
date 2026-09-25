import DirigibleCore

/// The zoom of a timeline (decision 0017). Window state, never saved.
struct TimelineScale: Hashable {
    var framesPerPoint: Double
}

/// The in point, the out point, and the selected tracks of a window (decision 0017). Window
/// state in `SessionWindow`, never in `Session`.
struct Marks: Hashable {
    var inPoint: Frames?
    var outPoint: Frames?
    var tracks: Set<TrackID> = []

    /// The one read of the selection: nil unless in < out and at least one selected track exists
    /// in `session`. The tracks are in session order, so a track that an undo removed drops out.
    func selection(in session: Session) -> (range: Range<Frames>, tracks: [TrackID])? {
        guard let inPoint, let outPoint, inPoint < outPoint else { return nil }
        let kept = session.tracks.map(\.id).filter(tracks.contains)
        return kept.isEmpty ? nil : (inPoint..<outPoint, kept)
    }
}
