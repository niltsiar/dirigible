import DirigibleCore
import Foundation

/// The scope of a ripple edit (decision 0037).
extension Marks {
    /// The range of the selection, the tracks that ripple, the tracks that the edit names, and the
    /// selected tracks that cut (the excerpt of a Cut and of a Copy). The tracks are all tracks of
    /// the session, or with `selectedOnly` (the "in Selected Tracks" items) only the selected
    /// tracks. The named tracks are the selected tracks, or none for tracks by default with no
    /// `selectedOnly`, so each follow track follows (decision 0073). Nil with no selection.
    public func rippleScope(selectedOnly: Bool, in session: Session)
        -> (range: Range<Frames>, tracks: [TrackID], named: [TrackID], selected: [TrackID])?
    {
        guard let selection = selection(in: session) else { return nil }
        let tracks = selectedOnly ? selection.tracks : session.tracks.map(\.id)
        let named = tracksByDefault && !selectedOnly ? [] : selection.tracks
        return (selection.range, tracks, named, session.cuttingTracks(selection.tracks, naming: named))
    }
}
