import DirigibleCore
import Foundation

/// The clip move part of the gesture (decision 0020): a drag of the upper part of a clip moves it
/// in time and to a lane of the same layout, and a click selects the clip.
extension TimelineGesture {
    /// A clip move: the target (track and start) and the session with the clip there.
    struct Move: Sendable {
        let clip: Clip
        let lane: Int
        var track: TrackID
        var start: Frames
        var preview: Session
    }

    /// A move drag event: the clip follows the pointer, and the preview has the clip there.
    mutating func moveDrag(_ press: Press, _ move: Move, _ x: Double, _ y: Double, _ context: GestureContext)
        -> [GestureEffect]
    {
        var move = move
        let geometry = context.geometry
        guard context.canEdit else {
            state = .dropped
            return []
        }
        let base = press.base
        let delta = press.delta(to: x, geometry)
        let start = min(max(.zero, move.clip.start + delta), .limit - move.clip.length)
        // Half a lane of vertical movement changes the lane; a lane of another layout keeps it.
        let lane = min(
            max(0, move.lane + Int(((y - press.y) / geometry.laneHeight).rounded())), base.tracks.count - 1)
        let source = base.tracks[move.lane]
        let track = base.tracks[lane].layout == source.layout ? base.tracks[lane].id : source.id
        guard (track, start) != (move.track, move.start) else { return [] }
        var preview = base
        // No gesture input reaches a throw (the clamp and the layout check run first). A throw
        // keeps the last preview (decision 0020).
        guard (try? preview.move(move.clip.id, to: track, start: start)) != nil else { return [] }
        (move.track, move.start, move.preview) = (track, start, preview)
        state = .moving(press, move)
        return []
    }

    /// A mouse-up under the threshold. On a clip: the clip range on its track, no seek. In the
    /// range zone (and every press with Shift or Command), the rules of decision 0017.
    func click(_ press: Press, _ context: GestureContext) -> [GestureEffect] {
        guard case .lane(let hit) = press.target else { return rulerClick(press) }
        switch hit {
        case .move(let clip, let lane), .trim(let clip, _, let lane), .gain(let clip, let lane),
            .fade(let clip, _, let lane):
            return [.marks(Marks(inPoint: clip.start, outPoint: clip.end, tracks: [press.base.tracks[lane].id]))]
        case .range(let lane):
            guard let lane, context.session.tracks.indices.contains(lane) else { return [] }
            let track = context.session.tracks[lane].id
            if press.shift {
                return [.marks(context.marks.extended(to: press.frame, lane: track, playhead: context.playhead))]
            }
            if press.command { return [.marks(context.marks.toggled(track))] }
            return [.marks(Marks()), .seek(press.frame)]
        }
    }

    /// The mouse-up of a move: one commit when the target changed, with the Marks on the new place.
    /// A move back to the start is a click.
    func commit(_ press: Press, _ move: Move, _ context: GestureContext) -> [GestureEffect] {
        guard (move.track, move.start) != (press.base.tracks[move.lane].id, move.clip.start) else {
            return click(press, context)
        }
        let marks = Marks(inPoint: move.start, outPoint: move.start + move.clip.length, tracks: [move.track])
        return [.commit(GestureCommit(base: press.base, result: move.preview, marks: marks, marker: nil))]
    }
}
