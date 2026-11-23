import DirigibleCore
import Foundation

/// The track half of `pasteClipboard`: the target tracks and the paste, on a copy of the session.
/// `copyExcerptFiles` gives it the excerpt with the records of the copied files.
struct PastePlan {
    var session: Session
    var clips: [ClipID] = []
    var tracks: [TrackID] = []

    init(_ excerpt: Excerpt, same: Bool, into session: Session, mode: PasteMode, on target: PasteTarget)
        throws(SessionError)
    {
        self.session = session
        switch target {
        case .tracks(let ids): tracks = ids
        case .extending(let ids):
            tracks = ids
            for lane in excerpt.lanes.dropFirst(ids.count) { tracks.append(try addTrack(for: lane)) }
        case .unselected where same:
            for lane in excerpt.lanes {
                tracks.append(self.session.track(lane.source) != nil ? lane.source : try addTrack(for: lane))
            }
        case .unselected:
            for lane in excerpt.lanes { tracks.append(try addTrack(for: lane)) }
        }
        clips = try self.session.paste(excerpt, mode: mode, on: tracks)
    }

    /// A new last track named after `lane`, with its layout.
    private mutating func addTrack(for lane: Excerpt.Lane) throws(SessionError) -> TrackID {
        let id = TrackID()
        try session.addTrack(id, name: lane.name, layout: lane.layout)
        return id
    }
}
