import DirigibleCore
import Foundation

/// The clip move part of the gesture (decision 0020): a drag of the upper part of a clip moves it
/// in time and to a lane of the same layout, and a click selects the clip. A drag of a clip of a
/// selection of 2 or more clips moves them all, and a Command-click toggles a clip (decision 0038).
extension TimelineGesture {
    /// A clip move: the target (track and start) and the session with the clip there.
    struct Move: Sendable {
        let clip: Clip
        let lane: Int
        var track: TrackID
        var start: Frames
        var preview: Session
        /// The snap targets: every clip but this one.
        let snap: Snap
        var guide: Frames? = nil
    }

    /// A group move: the selected clips at the down with their lanes, one frame offset and one lane
    /// offset for all, and the session with the clips there.
    struct GroupMove: Sendable {
        let clips: [(clip: Clip, lane: Int)]
        var offset = Frames.zero
        var lanes = 0
        var preview: Session
        /// The clip under the pointer: only its edges snap.
        let anchor: Clip
        /// The snap targets: every clip that is not in the group.
        let snap: Snap
        var guide: Frames? = nil
    }

    /// The drag of the clip at the down: a group move when the selection holds the clip and 2 or
    /// more clips, else a single move.
    func moveState(_ press: Press, _ clip: Clip, _ lane: Int, _ geometry: LaneGeometry) -> State {
        let held = press.selection.selectedClips(in: press.base)
        guard held.count >= 2, held.contains(where: { $0.clip.id == clip.id }) else {
            let track = press.base.tracks[lane].id
            let snap = Snap(press.base, excluding: [clip.id], geometry: geometry)
            return .moving(
                press, Move(clip: clip, lane: lane, track: track, start: clip.start, preview: press.base, snap: snap))
        }
        let snap = Snap(press.base, excluding: Set(held.map(\.clip.id)), geometry: geometry)
        return .grouping(press, GroupMove(clips: held, preview: press.base, anchor: clip, snap: snap))
    }

    /// A group drag event. The offset stops when the first clip reaches frame 0 or the last end
    /// reaches the limit; the lane offset stops when a clip reaches the first or the last track. A
    /// target track of the other layout keeps every clip on its lane (the single-move rule).
    mutating func groupDrag(_ press: Press, _ group: GroupMove, _ x: Double, _ y: Double, _ context: GestureContext)
        -> [GestureEffect]
    {
        guard context.canEdit else {
            state = .dropped
            return []
        }
        let base = press.base
        let starts = group.clips.map(\.clip.start)
        let ends = group.clips.map(\.clip.end)
        let lanes = group.clips.map(\.lane)
        let (first, last) = (starts.min() ?? .zero, ends.max() ?? .zero)
        let anchor = group.anchor
        let (raw, target) = Snap.snapped(
            group.snap, press.delta(to: x, context.geometry), [anchor.start, anchor.end], context)
        let offset = min(max(raw, .zero - first), .limit - last)
        var group = group
        group.guide = Snap.guide(target, on: [anchor.start + offset, anchor.end + offset])
        let wanted = Int(((y - press.y) / context.geometry.laneHeight).rounded())
        var delta = min(max(wanted, -(lanes.min() ?? 0)), base.tracks.count - 1 - (lanes.max() ?? 0))
        if group.clips.contains(where: { base.tracks[$0.lane + delta].layout != base.tracks[$0.lane].layout }) {
            delta = 0
        }
        guard (offset, delta) != (group.offset, group.lanes) else {
            state = .grouping(press, group)
            return []
        }
        var preview = base
        // The clamps and the layout check run first, so no gesture input reaches a throw. A throw
        // keeps the last preview (decision 0020) with no guide: its edge can be off the target.
        guard (try? preview.nudge(group.clips.map(\.clip.id), by: offset, lanes: delta)) != nil else {
            group.guide = nil
            state = .grouping(press, group)
            return []
        }
        (group.offset, group.lanes, group.preview) = (offset, delta, preview)
        state = .grouping(press, group)
        return []
    }

    /// The mouse-up of a group move: one commit, with the moved clips as the selection. A shifted
    /// range is not safe: a gap of the source range can land on clips that did not move. A group
    /// back at its start is a click.
    func commit(_ press: Press, _ group: GroupMove, _ context: GestureContext) -> [GestureEffect] {
        guard (group.offset, group.lanes) != (.zero, 0),
            let set = ClipSet(Set(group.clips.map(\.clip.id)))
        else { return click(press, context) }
        return [
            .commit(
                GestureCommit(
                    base: press.base, result: group.preview, selection: .clips(set), marker: nil, ripple: false))
        ]
    }

    /// A move drag event: the clip follows the pointer, and the preview has the clip there.
    mutating func moveDrag(_ press: Press, _ move: Move, _ x: Double, _ y: Double, _ context: GestureContext)
        -> [GestureEffect]
    {
        guard context.canEdit else {
            state = .dropped
            return []
        }
        var move = move
        let geometry = context.geometry
        let base = press.base
        let (delta, target) = Snap.snapped(
            move.snap, press.delta(to: x, geometry), [move.clip.start, move.clip.end], context)
        let start = min(max(.zero, move.clip.start + delta), .limit - move.clip.length)
        move.guide = Snap.guide(target, on: [start, start + move.clip.length])
        // Half a lane of vertical movement changes the lane; a lane of another layout keeps it.
        let lane = min(
            max(0, move.lane + Int(((y - press.y) / geometry.laneHeight).rounded())), base.tracks.count - 1)
        let source = base.tracks[move.lane]
        let track = base.tracks[lane].layout == source.layout ? base.tracks[lane].id : source.id
        guard (track, start) != (move.track, move.start) else {
            state = .moving(press, move)
            return []
        }
        var preview = base
        // No gesture input reaches a throw (the clamp and the layout check run first). A throw
        // keeps the last preview (decision 0020) with no guide: its edge can be off the target.
        guard (try? preview.move(move.clip.id, to: track, start: start)) != nil else {
            move.guide = nil
            state = .moving(press, move)
            return []
        }
        (move.track, move.start, move.preview) = (track, start, preview)
        state = .moving(press, move)
        return []
    }

    /// A mouse-up under the threshold. On a clip: the clip as a set of one clip, no seek; with Command,
    /// the clip toggles in the clip set (decision 0038). In the range zone (and every press with
    /// Shift), the rules of decision 0017; with Command and a clip set, no change.
    func click(_ press: Press, _ context: GestureContext) -> [GestureEffect] {
        guard case .lane(let hit) = press.target else { return rulerClick(press) }
        switch hit {
        case .move(let clip, _), .trim(let clip, _, _), .gain(let clip, _), .fade(let clip, _, _),
            .point(let clip, _, _):
            if press.command { return [.selection(context.selection.toggling(clip.id, in: context.session))] }
            return [.selection(.clips(ClipSet(clip.id)))]
        case .range(let lane):
            guard let lane, context.session.tracks.indices.contains(lane) else { return [] }
            let track = context.session.tracks[lane].id
            if press.shift {
                return [
                    .selection(.range(context.marks.extended(to: press.frame, lane: track, playhead: context.playhead)))
                ]
            }
            if press.command {
                guard case .range(let marks) = context.selection else { return [] }
                return [.selection(.range(marks.toggled(track)))]
            }
            return [.selection(.none), .seek(press.frame)]
        }
    }

    /// The mouse-up of a move: one commit when the target changed, with the moved clip selected.
    /// A move back to the start is a click.
    func commit(_ press: Press, _ move: Move, _ context: GestureContext) -> [GestureEffect] {
        guard (move.track, move.start) != (press.base.tracks[move.lane].id, move.clip.start) else {
            return click(press, context)
        }
        return [
            .commit(
                GestureCommit(
                    base: press.base, result: move.preview, selection: .clips(ClipSet(move.clip.id)), marker: nil,
                    ripple: false))
        ]
    }
}
