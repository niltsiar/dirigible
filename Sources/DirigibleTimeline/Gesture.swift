import DirigibleCore
import Foundation

/// What the gesture reads at each event (decision 0020). `canEdit` is false while a take starts,
/// records, or finalizes. `canRipple` is false while a take is pending or split (decision 0037).
public struct GestureContext: Sendable {
    public var session: Session
    public var marks: Marks
    public var playhead: Frames
    public var geometry: LaneGeometry
    public var canEdit: Bool
    public var canRipple: Bool

    public init(
        session: Session, marks: Marks, playhead: Frames, geometry: LaneGeometry, canEdit: Bool, canRipple: Bool
    ) {
        (self.session, self.marks, self.playhead, self.geometry, self.canEdit, self.canRipple) =
            (session, marks, playhead, geometry, canEdit, canRipple)
    }
}

/// A mouse event of the lanes, Esc, or a change of the session under an active gesture. `clicks`
/// is the click count of the mouse-down (2 for a double-click). Option on a trim zone makes a
/// ripple trim (decision 0037).
public enum GestureEvent: Equatable, Sendable {
    case down(Place, shift: Bool, command: Bool, option: Bool = false, clicks: Int = 1)
    case drag(Place)
    case up(Place)
    case escape
    case sessionChanged
}

/// What the window does for an event.
public enum GestureEffect: Equatable, Sendable {
    case marks(Marks)
    case seek(Frames)
    /// The current marker of the window (decision 0018).
    case currentMarker(MarkerID)
    case commit(GestureCommit)
    /// A refused press: an Option press on a trim zone under a pending or split take (0037).
    case beep
}

/// One Core edit on the session of the mouse-down (`base`), and the Marks or the current marker
/// after it. Only the gesture makes one.
public struct GestureCommit: Equatable, Sendable {
    let base: Session
    let result: Session
    public let marks: Marks?
    public let marker: MarkerID?

    /// Sets `session` to the result when it is still `base` and returns true; else changes nothing
    /// and returns false. So an undo, a redo, or another edit during a drag drops the gesture with
    /// no alert and no undo entry.
    public func apply(to session: inout Session) -> Bool {
        guard session == base else { return false }
        session = result
        return true
    }
}

extension Place {
    var point: (x: Double, y: Double) {
        switch self {
        case .lanes(let x, let y), .ruler(let x, let y): (x, y)
        }
    }
}

/// The one gesture of the lanes and the ruler (decision 0020). A value type: the scroll view
/// owns it, gives it each event with the context, and does the effects.
public struct TimelineGesture: Sendable {
    /// What a mouse-down holds: a lane zone, a ruler flag (the marker at the down), or a triangle.
    enum Target: Sendable {
        case lane(LaneHit)
        case flag(Marker)
        case point(MarkPoint)
    }

    /// The mouse-down: its target, point, frame, modifiers, click count, and the session and Marks
    /// at that time.
    struct Press: Sendable {
        let target: Target
        let x, y: Double
        let frame: Frames
        let shift, command, option: Bool
        let clicks: Int
        let marks: Marks
        let base: Session

        /// The frames from the down to `x`: zero under the threshold of horizontal movement, so the
        /// jitter of a click or a drag to another lane never changes the time of an edit.
        func delta(to x: Double, _ geometry: LaneGeometry) -> Frames {
            abs(x - self.x) < TimelineGesture.threshold ? .zero : geometry.frame(at: x) - frame
        }
    }

    /// A clip move: the target (track and start) and the session with the clip there.
    struct Move: Sendable {
        let clip: Clip
        let lane: Int
        var track: TrackID
        var start: Frames
        var preview: Session
    }

    /// A trim of one edge: the frames that the edge can reach (`trimLimits` at the drag start) and
    /// the session with the clip at `range`. A ripple trim (decision 0037) holds the deltas that
    /// the edge can take (`rippleTrimLimits`) in `limits`.
    struct Trim: Sendable {
        let clip: Clip
        let edge: Edge
        let lane: Int
        let ripple: Bool
        let limits: ClosedRange<Frames>
        var range: Range<Frames>
        var preview: Session
    }

    enum State: Sendable {
        case idle
        /// Esc, a session change, or a take ended the gesture: input is ignored until the up.
        case dropped
        case pressed(Press)
        case moving(Press, Move)
        case trimming(Press, Trim)
        /// A drag of the gain line, of a fade handle, or of a crossfade handle (`Gesture+Clip.swift`).
        case gaining(Press, GainDrag)
        case fading(Press, FadeDrag)
        case crossfading(Press, CrossfadeDrag)
        case ranging(Press)
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

    /// True in a drag that follows the pointer: a move, a trim, a fade handle, a range, a flag, or
    /// a triangle. Autoscroll runs only then (decision 0025).
    public var autoscrolls: Bool {
        switch state {
        case .moving, .trimming, .fading, .crossfading, .ranging, .markerDrag, .pointDrag: true
        case .idle, .dropped, .pressed, .gaining: false
        }
    }

    public mutating func handle(_ event: GestureEvent, _ context: GestureContext) -> [GestureEffect] {
        switch event {
        case .down(let place, let shift, let command, let option, let clicks):
            state = .idle
            let target: Target
            switch place {
            case .lanes(let x, let y):
                let hit = context.geometry.hit(x, y, in: context.session)
                target = .lane(shift || command ? .range(lane: hit.lane) : hit)
            case .ruler(let x, let y):
                switch rulerTarget(x, y, context) {
                case .none: return []
                case .seek(let frame): return [.seek(frame)]
                case .press(let pressed): target = pressed
                }
            }
            let (x, y) = place.point
            state = .pressed(
                Press(
                    target: target, x: x, y: y, frame: context.geometry.frame(at: x), shift: shift, command: command,
                    option: option, clicks: clicks, marks: context.marks, base: context.session))
            return []
        case .drag(let place):
            return drag(place, context)
        case .up(let place):
            let effects = drag(place, context)
            defer { state = .idle }
            switch state {
            case .pressed(let press): return reset(press, context) ?? click(press, context)
            case .moving(let press, let move): return commit(press, move, context)
            case .trimming(let press, let trim): return commit(press, trim, context)
            case .gaining(let press, let gain): return commit(press, gain, context)
            case .fading(let press, let fade): return commit(press, fade, context)
            case .crossfading(let press, let crossfade): return commit(press, crossfade, context)
            case .markerDrag(let press, let original, let preview): return commit(press, original, preview)
            case .ranging, .pointDrag: return effects
            case .idle, .dropped: return []
            }
        case .escape:
            switch state {
            case .idle, .dropped: return []
            case .pressed:
                state = .idle
                return []
            case .moving, .trimming, .gaining, .fading, .crossfading, .markerDrag:
                state = .dropped
                return []
            case .ranging(let press), .pointDrag(let press, _):
                state = .dropped
                return [.marks(press.marks)]
            }
        case .sessionChanged:
            switch state {
            case .moving, .trimming, .gaining, .fading, .crossfading, .markerDrag: state = .dropped
            case .pressed(let press) where press.target.edits: state = .idle
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
        case .trimming(_, let trim): trim.preview
        case .gaining(_, let gain): gain.preview
        case .fading(_, let fade): fade.preview
        case .crossfading(_, let crossfade): crossfade.preview
        case .markerDrag(_, _, let preview): preview
        default: session
        }
    }

    /// The cursor at `place`: the kind of the gesture while it runs, else the kind of the zone.
    /// With `option`, a trim zone gives the ripple cursor of its edge (decision 0037).
    public func cursor(at place: Place, _ context: GestureContext, option: Bool = false) -> TimelineCursor {
        switch state {
        case .moving: return .closedHand
        case .trimming(_, let trim) where trim.ripple: return .rippleTrim(trim.edge)
        case .trimming, .fading, .crossfading, .markerDrag, .pointDrag: return .resizeLeftRight
        case .gaining: return .resizeUpDown
        case .ranging: return .iBeam
        case .idle, .dropped, .pressed: break
        }
        switch place {
        case .lanes(let x, let y):
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
                let track = press.base.tracks[lane].id
                state = .moving(
                    press, Move(clip: clip, lane: lane, track: track, start: clip.start, preview: press.base))
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
                state = .gaining(press, GainDrag(clip: clip, lane: lane, gain: clip.gain, preview: press.base))
                return drag(place, context)
            case .lane(.fade(let clip, let edge, let lane)):
                guard context.canEdit else { return [] }
                state = handleState(press, clip, edge, lane)
                return drag(place, context)
            case .lane(.range):
                state = .ranging(press)
                return drag(place, context)
            }
        case .moving(let press, var move):
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
        case .trimming(let press, var trim):
            guard context.canEdit else {
                state = .dropped
                return []
            }
            if trim.ripple { return rippleDrag(press, trim, x, geometry) }
            let delta = press.delta(to: x, geometry)
            let edge = trim.edge == .start ? trim.clip.start : trim.clip.end
            let frame = min(max(edge + delta, trim.limits.lowerBound), trim.limits.upperBound)
            let range = trim.edge == .start ? frame..<trim.clip.end : trim.clip.start..<frame
            guard range != trim.range else { return [] }
            var preview = press.base
            // `trimLimits` keeps every range inside the neighbors and the file, so no input reaches a
            // throw. A throw keeps the last preview (decision 0020).
            guard (try? preview.trim(trim.clip.id, to: range)) != nil else { return [] }
            (trim.range, trim.preview) = (range, preview)
            state = .trimming(press, trim)
            return []
        case .gaining(let press, let gain):
            return gainDrag(press, gain, y, context)
        case .fading(let press, let fade):
            return fadeDrag(press, fade, x, context)
        case .crossfading(let press, let crossfade):
            return crossfadeDrag(press, crossfade, x, context)
        case .ranging(let press):
            let drag = Marks.drag(
                from: press.frame, to: geometry.frame(at: x), lanes: (geometry.lane(at: press.y), geometry.lane(at: y)),
                in: context.session)
            return [.marks(press.shift ? press.marks.extended(by: drag) : drag)]
        case .markerDrag(let press, let original, _):
            return markerDrag(press, original, x, context)
        case .pointDrag(let press, let point):
            return pointDrag(press, point, x, context)
        }
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
    private func commit(_ press: Press, _ move: Move, _ context: GestureContext) -> [GestureEffect] {
        guard (move.track, move.start) != (press.base.tracks[move.lane].id, move.clip.start) else {
            return click(press, context)
        }
        let marks = Marks(inPoint: move.start, outPoint: move.start + move.clip.length, tracks: [move.track])
        return [.commit(GestureCommit(base: press.base, result: move.preview, marks: marks, marker: nil))]
    }

    /// The mouse-up of a trim: one commit when the range changed, with the Marks on the new range.
    /// An edge back at its start is a click.
    private func commit(_ press: Press, _ trim: Trim, _ context: GestureContext) -> [GestureEffect] {
        guard trim.range != trim.clip.range else { return click(press, context) }
        let marks = Marks(
            inPoint: trim.range.lowerBound, outPoint: trim.range.upperBound, tracks: [press.base.tracks[trim.lane].id])
        return [.commit(GestureCommit(base: press.base, result: trim.preview, marks: marks, marker: nil))]
    }
}
