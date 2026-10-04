import DirigibleCore
import Foundation

/// The scope of a ripple edit (decision 0037).
extension Marks {
    /// The range of the selection, the tracks that ripple, and the selected tracks (the excerpt of
    /// a Cut). The tracks are all tracks of the session, or with `selectedOnly` (the "in Selected
    /// Tracks" items) only the selected tracks. Nil with no selection.
    public func rippleScope(selectedOnly: Bool, in session: Session)
        -> (range: Range<Frames>, tracks: [TrackID], selected: [TrackID])?
    {
        guard let selection = selection(in: session) else { return nil }
        let tracks = selectedOnly ? selection.tracks : session.tracks.map(\.id)
        return (selection.range, tracks, selection.tracks)
    }
}
