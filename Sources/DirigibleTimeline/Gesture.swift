import DirigibleCore
import Foundation

/// The one gesture of the lanes and the ruler (decision 0020). A value type: the scroll view
/// owns it, gives it each event with the context, and does the effects.
public struct TimelineGesture: Sendable {
    /// What a mouse-down holds: a lane zone, a ruler flag (the marker at the down), a triangle, or
    /// the time area of the ruler.
    enum Target: Sendable {
        case lane(LaneHit)
        case time
        case flag(Marker)
        case point(MarkPoint)
    }

    /// The mouse-down: its target, point, frame, modifiers, click count, and the session and the
    /// selection at that time.
    struct Press: Sendable {
        let target: Target
        let x, y: Double
        let frame: Frames
        let shift, command, option: Bool
        let clicks: Int
        let selection: Selection
        let base: Session
        /// False when a range drag has no playhead snap target (`Target.snapsPlayhead`); set at the down.
        let snapsPlayhead: Bool
        /// The clip zone of a Shift-Command press with no Option (`Gesture+Roll.swift`): the target
        /// stays the range, so a click with no drag is the Shift click of decision 0017.
        let zone: RollSlipZone?

        /// True for a press that can start a session edit: a session change ends such a press.
        var edits: Bool { target.edits || zone != nil }

        /// The range of the selection at the down; no points for a clip set.
        var marks: Marks { selection.rangeMarks(in: base) }

        /// The frames from the down to `x`: zero under the threshold of horizontal movement, so the
        /// jitter of a click or a drag to another lane never changes the time of an edit.
        func delta(to x: Double, _ geometry: LaneGeometry) -> Frames {
            abs(x - self.x) < TimelineGesture.threshold ? .zero : geometry.frame(at: x) - frame
        }
    }

    /// A trim of one edge: the frames that the edge can reach (`trimLimits` at the drag start) and
    /// the session with the clip at `range`. A ripple trim (decision 0037) holds the deltas that
    /// the edge can take (`rippleTrimLimits`) in `limits`.
    struct Trim: Sendable {
        let clip: Clip
        let edge: Edge
        let ripple: Bool
        let limits: ClosedRange<Frames>
        var range: Range<Frames>
        var preview: Session
        /// The snap targets of the drag; nil for a ripple trim, which moves by whole device columns.
        let snap: Snap?
        var guide: Frames? = nil
    }

    enum State: Sendable {
        case idle
        /// Esc, a session change, or a take ended the gesture: input is ignored until the up.
        case dropped
        case pressed(Press)
        case moving(Press, Move)
        /// A drag of a clip of a selection of 2 or more clips (decision 0038).
        case grouping(Press, GroupMove)
        case trimming(Press, Trim)
        /// A Shift-Command drag of a join, and of the content of a clip (`Gesture+Roll.swift`).
        case rolling(Press, Roll)
        case slipping(Press, Slip)
        /// A drag of the gain line, of a fade handle, or of a crossfade handle (`Gesture+Clip.swift`).
        case gaining(Press, GainDrag)
        /// A drag of an envelope point, or of a point that an Option press added, and a drag of the
        /// line inside a range (`Gesture+Envelope.swift`).
        case pointing(Press, PointDrag)
        case rangeGaining(Press, RangeGainDrag)
        case fading(Press, FadeDrag)
        case crossfading(Press, CrossfadeDrag)
        /// A range drag, with its snap targets and the target that the pointer end is on.
        case ranging(Press, Snap, guide: Frames?)
        /// A Shift-drag on the lanes (decision 0038): the press and the pointer. The selection is the
        /// clips that the rectangle holds whole, and the session never changes.
        case marqueeing(Press, x: Double, y: Double)
        /// A flag drag: the marker at the down, and the session with the marker moved.
        case markerDrag(Press, Marker, preview: Session)
        /// A drag of the in or the out triangle: it changes the Marks only.
        case pointDrag(Press, MarkPoint)
    }

    /// Internal: `Gesture+Ruler.swift` sets it too.
    var state = State.idle

    /// The movement from the mouse-down that makes a drag (a calibration knob).
    static let threshold = 3.0

    public init() {}

    /// False only when no gesture runs, so Esc goes to the window.
    public var isActive: Bool {
        if case .idle = state { return false }
        return true
    }

    /// True in a drag that follows the pointer: a move, a trim, a fade handle, a range, a marquee, a
    /// flag, or a triangle. Autoscroll runs only then (decision 0025).
    public var autoscrolls: Bool {
        switch state {
        case .moving, .grouping, .trimming, .rolling, .fading, .crossfading, .ranging, .marqueeing, .markerDrag,
            .pointDrag:
            true
        case .idle, .dropped, .pressed, .gaining, .pointing, .rangeGaining, .slipping: false
        }
    }

    public mutating func handle(_ event: GestureEvent, _ context: GestureContext) -> [GestureEffect] {
        switch event {
        case .down(let place, let shift, let command, let option, let clicks):
            state = .idle
            let target: Target
            var zone: RollSlipZone?
            var effects: [GestureEffect] = []
            switch place {
            case .lanes(let x, let y):
                let hit = context.geometry.hit(x, y, in: context.session)
                // Shift makes a range press whose drag is a marquee (decision 0038). Command on a clip
                // keeps the clip for a toggle at the up.
                target = .lane(shift || (command && hit.clip == nil) ? .range(lane: hit.lane) : hit)
                if shift, command, !option { zone = Self.rollSlipZone(x, y, in: context.session, context.geometry) }
            case .ruler(let x, let y):
                switch rulerTarget(x, y, context) {
                case .none: return []
                case .seek(let frame):
                    target = .time
                    effects = [.seek(frame)]
                case .press(let pressed): target = pressed
                }
            }
            let (x, y) = place.point
            let frame = context.geometry.frame(at: x)
            state = .pressed(
                Press(
                    target: target, x: x, y: y, frame: frame, shift: shift, command: command, option: option,
                    clicks: clicks, selection: context.selection, base: context.session,
                    snapsPlayhead: target.snapsPlayhead(at: frame, context), zone: zone))
            return effects
        case .drag(let place):
            return drag(place, context)
        case .up(let place):
            let effects = drag(place, context)
            defer { state = .idle }
            switch state {
            case .pressed(let press): return reset(press, context) ?? addPoint(press, context) ?? click(press, context)
            case .moving(let press, let move): return commit(press, move, context)
            case .grouping(let press, let group): return commit(press, group, context)
            case .trimming(let press, let trim): return commit(press, trim, context)
            case .rolling(let press, let roll): return commit(press, roll.clip, roll.delta, roll.preview, context)
            case .slipping(let press, let slip): return commit(press, slip.clip, slip.delta, slip.preview, context)
            case .gaining(let press, let gain): return commit(press, gain, context)
            case .pointing(let press, let point): return commit(press, point, context)
            case .rangeGaining(let press, let gain): return commit(press, gain, context)
            case .fading(let press, let fade): return commit(press, fade, context)
            case .crossfading(let press, let crossfade): return commit(press, crossfade, context)
            case .markerDrag(let press, let original, let preview): return commit(press, original, preview)
            case .ranging(let press, _, _): return press.target.isTime ? rulerRangeUp(effects) : effects
            case .marqueeing, .pointDrag: return effects
            case .idle, .dropped: return []
            }
        case .escape:
            switch state {
            case .idle, .dropped: return []
            case .pressed:
                state = .idle
                return []
            case .moving, .grouping, .trimming, .rolling, .slipping, .gaining, .pointing, .rangeGaining, .fading,
                .crossfading, .markerDrag:
                state = .dropped
                return []
            case .ranging(let press, _, _), .marqueeing(let press, _, _), .pointDrag(let press, _):
                state = .dropped
                return [.selection(press.selection)]
            }
        case .sessionChanged:
            switch state {
            case .moving, .grouping, .trimming, .rolling, .slipping, .gaining, .pointing, .rangeGaining, .fading,
                .crossfading, .markerDrag:
                state = .dropped
            case .pressed(let press) where press.edits: state = .idle
            // An undo or a take changes the clip edges: the range drag snaps to the new session.
            case .ranging(let press, _, _): state = rangeState(press, context)
            default: break
            }
            return []
        }
    }

    /// The session to draw over the inputs: the preview of a move, a trim, a gain or fade drag, or
    /// a flag drag.
    public func drawn(_ session: Session) -> Session {
        switch state {
        case .moving(_, let move): move.preview
        case .grouping(_, let group): group.preview
        case .trimming(_, let trim): trim.preview
        case .rolling(_, let roll): roll.preview
        case .slipping(_, let slip): slip.preview
        case .gaining(_, let gain): gain.preview
        case .pointing(_, let point): point.preview
        case .rangeGaining(_, let gain): gain.preview
        case .fading(_, let fade): fade.preview
        case .crossfading(_, let crossfade): crossfade.preview
        case .markerDrag(_, _, let preview): preview
        default: session
        }
    }

    /// The cursor at `place`: the kind of the gesture while it runs, else the kind of the zone.
    /// With `option`, a trim zone gives the ripple cursor of its edge (decision 0037). With `shift` and
    /// `command` and no `option`, the cursor is that of a Shift-Command press (`Gesture+Roll.swift`).
    public func cursor(
        at place: Place, _ context: GestureContext, option: Bool = false, shift: Bool = false, command: Bool = false
    ) -> TimelineCursor {
        switch state {
        case .moving, .grouping: return .closedHand
        case .trimming(_, let trim) where trim.ripple: return .rippleTrim(trim.edge)
        case .trimming, .rolling, .fading, .crossfading, .markerDrag, .pointDrag: return .resizeLeftRight
        case .slipping: return .openHand
        case .gaining, .rangeGaining: return .resizeUpDown
        case .pointing: return .closedHand
        case .ranging: return .iBeam
        case .marqueeing: return .arrow
        case .idle, .dropped, .pressed: break
        }
        switch place {
        case .lanes(let x, let y):
            if shift, command, !option { return rollSlipCursor(x, y, context) }
            let hit = context.geometry.hit(x, y, in: context.session)
            if option, case .trim(_, let edge, _) = hit { return .rippleTrim(edge) }
            return hit.cursor
        case .ruler(let x, let y): return context.rulerHit(x, y)?.cursor ?? .arrow
        }
    }

    private mutating func drag(_ place: Place, _ context: GestureContext) -> [GestureEffect] {
        let (x, y) = place.point
        let geometry = context.geometry
        switch state {
        case .idle, .dropped:
            return []
        case .pressed(let press):
            guard hypot(x - press.x, y - press.y) >= Self.threshold else { return [] }
            if let zone = press.zone {
                guard context.canEdit else { return [] }
                guard let next = rollSlipState(press, zone, context) else { return [] }
                state = next
                return drag(place, context)
            }
            // A Command-drag from a clip stays a range drag (decision 0020).
            if press.command, case .lane(let hit) = press.target, hit != .range(lane: nil) {
                state = rangeState(press, context)
                return drag(place, context)
            }
            switch press.target {
            case .flag(let marker):
                guard context.canEdit else { return [] }
                state = .markerDrag(press, marker, preview: press.base)
                return drag(place, context)
            case .point(let point):
                state = .pointDrag(press, point)
                return drag(place, context)
            case .lane(.move(let clip, let lane)):
                guard context.canEdit else { return [] }
                state = moveState(press, clip, lane, context.geometry)
                return drag(place, context)
            case .lane(.trim(let clip, let edge, let lane)):
                guard context.canEdit else { return [] }
                // A ripple trim that cannot ripple: one beep, and the press ends (decision 0037).
                if press.option, !context.canRipple {
                    state = .dropped
                    return [.beep]
                }
                guard let trim = trim(press, clip, edge, lane, context) else { return [] }
                state = .trimming(press, trim)
                return drag(place, context)
            case .lane(.gain(let clip, let lane)):
                guard context.canEdit else { return [] }
                state = gainState(press, clip, lane)
                return drag(place, context)
            case .lane(.point(let clip, let index, _)):
                guard context.canEdit, let pointing = pointState(press, clip, index: index) else { return [] }
                state = pointing
                return drag(place, context)
            case .lane(.fade(let clip, let edge, let lane)):
                guard context.canEdit else { return [] }
                state = handleState(press, clip, edge, lane)
                return drag(place, context)
            case .time:
                guard abs(x - press.x) >= Self.threshold else { return [] }
                state = rangeState(press, context)
                return drag(place, context)
            case .lane(.range(let lane)):
                // A drag from under the last lane changes nothing (decision 0017). Shift draws a
                // marquee; a Shift-Command press took the Command branch above.
                state =
                    lane == nil ? .dropped : press.shift ? .marqueeing(press, x: x, y: y) : rangeState(press, context)
                return drag(place, context)
            }
        case .moving(let press, let move):
            return moveDrag(press, move, x, y, context)
        case .grouping(let press, let group):
            return groupDrag(press, group, x, y, context)
        case .trimming(let press, var trim):
            guard context.canEdit else {
                state = .dropped
                return []
            }
            if trim.ripple { return rippleDrag(press, trim, x, context) }
            let edge = trim.edge == .start ? trim.clip.start : trim.clip.end
            let (delta, target) = Snap.snapped(trim.snap, press.delta(to: x, geometry), [edge], context)
            let frame = min(max(edge + delta, trim.limits.lowerBound), trim.limits.upperBound)
            let range = trim.edge == .start ? frame..<trim.clip.end : trim.clip.start..<frame
            trim.guide = Snap.guide(target, on: [frame])
            guard range != trim.range else {
                state = .trimming(press, trim)
                return []
            }
            var preview = press.base
            // `trimLimits` keeps every range inside the neighbors and the file, so no input reaches a
            // throw. A throw keeps the last preview (decision 0020) with no guide.
            guard (try? preview.trim(trim.clip.id, to: range)) != nil else {
                trim.guide = nil
                state = .trimming(press, trim)
                return []
            }
            (trim.range, trim.preview) = (range, preview)
            state = .trimming(press, trim)
            return []
        case .rolling(let press, let roll):
            return rollDrag(press, roll, x, context)
        case .slipping(let press, let slip):
            return slipDrag(press, slip, x, context)
        case .gaining(let press, let gain):
            return gainDrag(press, gain, y, context)
        case .pointing(let press, let point):
            return pointDrag(press, point, x, y, context)
        case .rangeGaining(let press, let gain):
            return rangeGainDrag(press, gain, y, context)
        case .fading(let press, let fade):
            return fadeDrag(press, fade, x, context)
        case .crossfading(let press, let crossfade):
            return crossfadeDrag(press, crossfade, x, context)
        case .ranging(let press, let snap, _):
            return rangeDrag(press, snap, x, y, context)
        case .marqueeing(let press, _, _):
            return marqueeDrag(press, x, y, context)
        case .markerDrag(let press, let original, _):
            return markerDrag(press, original, x, context)
        case .pointDrag(let press, let point):
            return pointDrag(press, point, x, context)
        }
    }
}
