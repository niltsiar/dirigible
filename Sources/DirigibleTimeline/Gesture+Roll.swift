import DirigibleCore
import Foundation

/// The Shift-Command drags on a clip (decision 0020): the edge of a clip rolls the join that it
/// touches, or trims a loose edge, and the upper part of a clip slips its content. The drags never
/// snap, and each event is one Core call on the session of the press.
extension TimelineGesture {
    /// What a Shift-Command press holds on a clip.
    enum RollSlipZone: Equatable, Sendable {
        case edge(Clip, Edge, lane: Int)
        case slip(Clip)
    }

    /// A roll drag: the left clip of the join, the frames that the join can move, the move, and
    /// the session with it. `clip` is the clip under the press.
    struct Roll: Sendable {
        let clip: Clip
        let left: ClipID
        let limits: ClosedRange<Frames>
        var delta: Frames
        var preview: Session
    }

    /// A slip drag: the clip, the frames that its content can move, the move, and the session with it.
    struct Slip: Sendable {
        let clip: Clip
        let limits: ClosedRange<Frames>
        var delta: Frames
        var preview: Session
    }

    /// The zone of a Shift-Command press at the lane point `x`, `y`; nil in a gap, in a box under
    /// `grabWidth`, and in the lower third of a clip, which keep the range drag. An edge zone wins
    /// over a fade handle or a point; within `moveHeight` of the box top, the other handles, the points, and the
    /// gain band slip.
    static func rollSlipZone(_ x: Double, _ y: Double, in session: Session, _ geometry: LaneGeometry) -> RollSlipZone? {
        let lane = geometry.lane(at: y)
        guard lane < session.tracks.count,
            let index = session.tracks[lane].clips.index(holding: geometry.frame(at: x))
        else { return nil }
        let clip = session.tracks[lane].clips[index]
        let box = geometry.box(of: clip, lane: lane)
        guard box.width >= LaneGeometry.grabWidth else { return nil }
        if x - box.minX < LaneGeometry.trimReach { return .edge(clip, .start, lane: lane) }
        if box.maxX - x < LaneGeometry.trimReach { return .edge(clip, .end, lane: lane) }
        guard y - box.minY < geometry.moveHeight else { return nil }
        switch geometry.hit(x, y, in: session) {
        case .move, .gain, .fade, .point: return .slip(clip)
        case .trim, .range: return nil
        }
    }

    /// The hover cursor of a Shift-Command press at `x`, `y`: the zone of the press, else the range cursor.
    func rollSlipCursor(_ x: Double, _ y: Double, _ context: GestureContext) -> TimelineCursor {
        switch Self.rollSlipZone(x, y, in: context.session, context.geometry) {
        case .edge: .resizeLeftRight
        case .slip: .openHand
        case nil: LaneHit.range(lane: context.geometry.hit(x, y, in: context.session).lane).cursor
        }
    }

    /// The drag of a zone at the 3 pt threshold: a roll at a join, else the plain trim of a loose
    /// edge, or a slip. Nil when the drag has no state: a file out of the pool.
    func rollSlipState(_ press: Press, _ zone: RollSlipZone, _ context: GestureContext) -> State? {
        switch zone {
        case .edge(let clip, let edge, let lane):
            let clips = press.base.tracks[lane].clips
            guard let left = Self.joinLeft(of: clip, edge, in: clips), left >= 0,
                let core = press.base.rollLimits(clips[left].id)
            else {
                return trim(press, clip, edge, lane, context).map { .trimming(press, $0) }
            }
            // Both clips keep 1 pt of length, as a trim does.
            let (a, b, shortest) = (clips[left], clips[left + 1], context.geometry.trimMinimum)
            let lower = max(core.lowerBound, .zero - (a.length - shortest))
            let upper = min(core.upperBound, b.length - shortest)
            let roll = Roll(
                clip: clip, left: a.id, limits: min(lower, .zero)...max(upper, .zero), delta: .zero,
                preview: press.base)
            return .rolling(press, roll)
        case .slip(let clip):
            guard let limits = try? press.base.slipLimits(clip.id) else { return nil }
            return .slipping(press, Slip(clip: clip, limits: limits, delta: .zero, preview: press.base))
        }
    }

    /// A roll drag event: the join follows the pointer, clamped to the limits. A take ends the drag.
    /// A throw keeps the last preview (decision 0020).
    mutating func rollDrag(_ press: Press, _ roll: Roll, _ x: Double, _ context: GestureContext) -> [GestureEffect] {
        guard context.canEdit else {
            state = .dropped
            return []
        }
        let delta = min(max(press.delta(to: x, context.geometry), roll.limits.lowerBound), roll.limits.upperBound)
        guard delta != roll.delta else { return [] }
        var preview = press.base
        guard (try? preview.roll(roll.left, by: delta)) != nil else { return [] }
        var roll = roll
        (roll.delta, roll.preview) = (delta, preview)
        state = .rolling(press, roll)
        return []
    }

    /// A slip drag event: the content follows the pointer, so a drag of d frames to the right slips
    /// by -d, clamped to the limits. A take ends the drag.
    mutating func slipDrag(_ press: Press, _ slip: Slip, _ x: Double, _ context: GestureContext) -> [GestureEffect] {
        guard context.canEdit else {
            state = .dropped
            return []
        }
        let pointer = press.delta(to: x, context.geometry)
        let delta = min(max(.zero - pointer, slip.limits.lowerBound), slip.limits.upperBound)
        guard delta != slip.delta else { return [] }
        var preview = press.base
        guard (try? preview.slip([slip.clip.id], by: delta)) != nil else { return [] }
        var slip = slip
        (slip.delta, slip.preview) = (delta, preview)
        state = .slipping(press, slip)
        return []
    }

    /// The mouse-up of a roll or a slip: one commit when the delta is not zero, with the pressed
    /// clip selected. A drag back to 0 is a click.
    func commit(_ press: Press, _ clip: Clip, _ delta: Frames, _ result: Session, _ context: GestureContext)
        -> [GestureEffect]
    {
        guard delta != .zero else { return click(press, context) }
        return [.commit(commit(press, clip, result))]
    }
}
