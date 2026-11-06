import DirigibleCore
import Foundation

/// The target rule of Roll Edit to Playhead (decision 0036).
extension Selection {
    /// The joins that Roll Edit to Playhead rolls, one per track, as `Session.roll(_:by:)` takes them.
    /// The tracks are the tracks of the range or of the clip set; with none, all tracks. On a track,
    /// the clip that holds the playhead rolls its nearer join with a touching neighbor to the
    /// playhead; a tie takes the join before the clip. A track with no such join, with the playhead
    /// in a gap or at the join, or with a delta outside `Session.rollLimits`, gives no roll.
    public func rollJoins(to playhead: Frames, in session: Session) -> [(left: ClipID, by: Frames)] {
        let chosen: Set<TrackID>
        switch self {
        case .range(let marks): chosen = marks.tracks
        case .clips: chosen = Set(selectedClips(in: session).map { session.tracks[$0.lane].id })
        }
        let lanes = session.tracks.filter { chosen.isEmpty || chosen.contains($0.id) }
        return lanes.compactMap { track -> (left: ClipID, by: Frames)? in
            let clips = Array(track.clips)
            guard let index = clips.firstIndex(where: { $0.start <= playhead && playhead < $0.end }) else {
                return nil
            }
            let clip = clips[index]
            var joins: [(left: ClipID, by: Frames)] = []
            if index > 0, clips[index - 1].end == clip.start {
                joins.append((clips[index - 1].id, playhead - clip.start))
            }
            if index + 1 < clips.count, clips[index + 1].start == clip.end {
                joins.append((clip.id, playhead - clip.end))
            }
            guard let join = joins.min(by: { abs($0.by.count) < abs($1.by.count) }), join.by != .zero,
                session.rollLimits(join.left)?.contains(join.by) == true
            else { return nil }
            return join
        }
    }
}
