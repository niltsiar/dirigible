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
        /// The drag mode of the press: a mode change in the context does not change this drag.
        let mode: DragMode
        /// No Overlap: the free starts on the target track (`Session.freeSpan`), and whether the
        /// last event clamped the start to them.
        var span: (track: TrackID, starts: ClosedRange<Frames>)? = nil
        var stopped = false
        /// Shuffle: the session of the mouse-down with the gap of the clip closed, made at the first
        /// drag event. The drop edge reads its target lane, and each event drops the clip on it. A
        /// reference: the debug frames of `drag` and `handle` grow with `State`, and a whole Session
        /// here overflows a test thread.
        var closed: Closed? = nil
    }

    /// A session on the heap, for `Move.closed`.
    final class Closed: Sendable {
        let session: Session
        init(_ session: Session) { self.session = session }
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
        /// The drag mode of the press.
        let mode: DragMode
        /// No Overlap: the last event would cover a clip, so the preview is the last free one.
        var stopped = false
    }

    /// The drag of the clip at the down: a group move when the selection holds the clip and 2 or
    /// more clips, else a single move.
    func moveState(_ press: Press, _ clip: Clip, _ lane: Int, _ geometry: LaneGeometry, _ mode: DragMode) -> State {
        let held = press.selection.selectedClips(in: press.base)
        guard held.count >= 2, held.contains(where: { $0.clip.id == clip.id }) else {
            let track = press.base.tracks[lane].id
            let snap = Snap(press.base, excluding: [clip.id], geometry: geometry)
            return .moving(
                press,
                Move(
                    clip: clip, lane: lane, track: track, start: clip.start, preview: press.base, snap: snap, mode: mode
                ))
        }
        let snap = Snap(press.base, excluding: Set(held.map(\.clip.id)), geometry: geometry)
        return .grouping(press, GroupMove(clips: held, preview: press.base, anchor: clip, snap: snap, mode: mode))
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
            group.stopped = false
            state = .grouping(press, group)
            return []
        }
        var preview = base
        // The clamps and the layout check run first, so only a No Overlap cover reaches a throw. A
        // throw keeps the last preview (decision 0020) with no guide: its edge can be off the target.
        do throws(SessionError) {
            try preview.nudge(group.clips.map(\.clip.id), by: offset, lanes: delta, mode: group.mode.overlap)
        } catch {
            group.guide = nil
            var effects: [GestureEffect] = []
            if case .overlap = error {
                if !group.stopped { effects = [.stopAnnouncement] }
                group.stopped = true
            }
            state = .grouping(press, group)
            return effects
        }
        (group.offset, group.lanes, group.preview, group.stopped) = (offset, delta, preview, false)
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
        var start = min(max(.zero, move.clip.start + delta), .limit - move.clip.length)
        move.guide = Snap.guide(target, on: [start, start + move.clip.length])
        // Half a lane of vertical movement changes the lane; a lane of another layout keeps it.
        let lane = min(
            max(0, move.lane + Int(((y - press.y) / geometry.laneHeight).rounded())), base.tracks.count - 1)
        let source = base.tracks[move.lane]
        let track = base.tracks[lane].layout == source.layout ? base.tracks[lane].id : source.id
        var effects: [GestureEffect] = []
        switch move.mode {
        case .noOverlap:
            guard let stop = noOverlapStart(&move, start, on: track, base) else {
                state = .moving(press, move)
                return []
            }
            if stop.stopped, !move.stopped { effects = [.stopAnnouncement] }
            move.stopped = stop.stopped
            start = stop.start
        case .shuffle:
            if move.closed == nil {
                var closed = base
                guard (try? closed.shuffleClose(move.clip, on: source.id)) != nil else {
                    state = .dropped
                    return [.beep]
                }
                move.closed = Closed(closed)
            }
            if let closed = move.closed, let edge = Self.dropEdge(start, on: track, in: closed.session.tracks) {
                (start, move.guide) = (edge, edge)
            }
        case .overwrite, .crossfade: break
        }
        guard (track, start) != (move.track, move.start) else {
            state = .moving(press, move)
            return effects
        }
        var preview = base
        // The clamps, the free span, and the layout check run first, so no gesture input reaches a
        // throw. A throw keeps the last preview (decision 0020) with no guide: its edge can be off
        // the target.
        do throws(SessionError) {
            if move.mode == .shuffle {
                // `shuffle` of the press session with the one close. Back at the clip start `shuffle`
                // changes nothing; a drop on the closed session there moves each marker in the clip to its end.
                if let closed = move.closed, (track, start) != (source.id, move.clip.start) {
                    preview = closed.session
                    try preview.shuffleDrop(move.clip, to: track, start: start)
                }
            } else {
                try preview.move(move.clip.id, to: track, start: start, mode: move.mode.overlap)
            }
        } catch {
            move.guide = nil
            state = .moving(press, move)
            return effects
        }
        (move.track, move.start, move.preview) = (track, start, preview)
        state = .moving(press, move)
        return effects
    }

    /// The No Overlap start of a move to `start` on `track`: clamped into one free span of the
    /// track, so the clip stops at its neighbors. The own track keeps the span of the
    /// mouse-down start; another track keeps the span near the first start on it. At a stop
    /// the guide is at the edge that touches the neighbor. Nil when the track has no free span.
    func noOverlapStart(_ move: inout Move, _ start: Frames, on track: TrackID, _ base: Session)
        -> (start: Frames, stopped: Bool)?
    {
        if move.span?.track != track {
            let near = track == base.tracks[move.lane].id ? move.clip.start : start
            guard let starts = try? base.freeSpan(of: move.clip.id, on: track, near: near) else { return nil }
            move.span = (track, starts)
        }
        guard let starts = move.span?.starts else { return nil }
        let clamped = min(max(start, starts.lowerBound), starts.upperBound)
        guard clamped != start else { return (start, false) }
        move.guide = clamped == starts.upperBound ? clamped + move.clip.length : clamped
        return (clamped, true)
    }

    /// The Shuffle drop of a wanted `start` on `track` of the `closed` tracks: the nearer edge of
    /// the clip that `start` cuts, and the clip start for a tie, so a drop never splits a clip.
    /// Nil when `start` cuts no clip.
    static func dropEdge(_ start: Frames, on track: TrackID, in closed: [Track]) -> Frames? {
        guard let lane = closed.first(where: { $0.id == track })?.clips,
            let index = lane.index(cutting: start)
        else { return nil }
        let clip = lane[index]
        return start - clip.start <= clip.end - start ? clip.start : clip.end
    }

    /// A mouse-up under the threshold. On a clip: the clip as a set of one clip, no seek; with Command,
    /// the clip toggles in the clip set (decision 0038). In the range zone, a plain click selects
    /// its track with no in or out point and seeks; with Shift, and with Command, the rules of
    /// decision 0017 (with Command and a clip set, no change). Under the last lane, a click changes
    /// nothing and a double-click clears the selection.
    func click(_ press: Press, _ context: GestureContext) -> [GestureEffect] {
        guard case .lane(let hit) = press.target else { return rulerClick(press) }
        switch hit {
        case .move(let clip, _), .trim(let clip, _, _), .gain(let clip, _), .fade(let clip, _, _),
            .point(let clip, _, _):
            if press.command { return [.selection(context.selection.toggling(clip.id, in: context.session))] }
            return [.selection(.clips(ClipSet(clip.id)))]
        case .range(let lane):
            guard let lane, context.session.tracks.indices.contains(lane) else {
                return press.clicks >= 2 ? [.selection(.none)] : []
            }
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
            return [.selection(.range(Marks(tracks: [track]))), .seek(press.frame)]
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
                    ripple: move.mode == .shuffle))
        ]
    }
}
