import DirigibleCore
import Foundation

/// What the gesture reads at each event (decision 0020). `canEdit` is false while a take starts,
/// records, or finalizes.
public struct GestureContext: Sendable {
    public var session: Session
    public var marks: Marks
    public var playhead: Frames
    public var geometry: LaneGeometry
    public var canEdit: Bool

    public init(session: Session, marks: Marks, playhead: Frames, geometry: LaneGeometry, canEdit: Bool) {
        (self.session, self.marks, self.playhead, self.geometry, self.canEdit) =
            (session, marks, playhead, geometry, canEdit)
    }
}

/// A mouse event of the lanes, Esc, or a change of the session under an active gesture.
public enum GestureEvent: Equatable, Sendable {
    case down(Place, shift: Bool, command: Bool)
    case drag(Place)
    case up(Place)
    case escape
    case sessionChanged
}

/// What the window does for an event.
public enum GestureEffect: Equatable, Sendable {
    case marks(Marks)
    case seek(Frames)
    case commit(GestureCommit)
}

/// One Core edit on the session of the mouse-down (`base`), and the Marks after it. Only the
/// gesture makes one.
public struct GestureCommit: Equatable, Sendable {
    let base: Session
    let result: Session
    public let marks: Marks?

    /// Sets `session` to the result when it is still `base` and returns true; else changes nothing
    /// and returns false. So an undo, a redo, or another edit during a drag drops the gesture with
    /// no alert and no undo entry.
    public func apply(to session: inout Session) -> Bool {
        guard session == base else { return false }
        session = result
        return true
    }
}

/// The one gesture of the lanes (decision 0020, design.md states x events). A value type: the
/// scroll view owns it, gives it each event with the context, and does the effects.
public struct TimelineGesture: Sendable {
    /// The mouse-down: its hit, point, frame, modifiers, and the session and Marks at that time.
    struct Press: Sendable {
        let hit: LaneHit
        let x, y: Double
        let frame: Frames
        let shift, command: Bool
        let marks: Marks
        let base: Session
    }

    /// A clip move: the target (track and start) and the session with the clip there.
    struct Move: Sendable {
        let clip: Clip
        let lane: Int
        var track: TrackID
        var start: Frames
        var preview: Session
    }

    enum State: Sendable {
        case idle
        /// Esc, a session change, or a take ended the gesture: input is ignored until the up.
        case dropped
        case pressed(Press)
        case moving(Press, Move)
        case ranging(Press)
    }

    private(set) var state = State.idle

    /// The movement from the mouse-down that makes a drag (a calibration knob).
    static let threshold = 3.0

    public init() {}

    /// False only when no gesture runs, so Esc goes to the window.
    public var isActive: Bool {
        if case .idle = state { return false }
        return true
    }

    public mutating func handle(_ event: GestureEvent, _ context: GestureContext) -> [GestureEffect] {
        switch event {
        case .down(let place, let shift, let command):
            state = .idle
            guard case .lanes(let x, let y) = place else { return [] }
            let geometry = context.geometry
            var hit = geometry.hit(x, y, in: context.session)
            if shift || command { hit = .range(lane: hit.lane) }
            state = .pressed(
                Press(
                    hit: hit, x: x, y: y, frame: geometry.frame(at: x), shift: shift, command: command,
                    marks: context.marks, base: context.session))
            return []
        case .drag(let place):
            return drag(place, context)
        case .up(let place):
            let effects = drag(place, context)
            defer { state = .idle }
            switch state {
            case .pressed(let press): return click(press, context)
            case .moving(let press, let move): return commit(press, move)
            case .ranging: return effects
            case .idle, .dropped: return []
            }
        case .escape:
            switch state {
            case .idle, .dropped: return []
            case .pressed:
                state = .idle
                return []
            case .moving:
                state = .dropped
                return []
            case .ranging(let press):
                state = .dropped
                return [.marks(press.marks)]
            }
        case .sessionChanged:
            if case .moving = state { state = .dropped }
            if case .pressed(let press) = state, press.hit.clip != nil { state = .idle }
            return []
        }
    }

    /// The session and the Marks to draw over the inputs: the preview of a move.
    public func drawn(session: Session, marks: Marks) -> (session: Session, marks: Marks) {
        if case .moving(_, let move) = state { return (move.preview, marks) }
        return (session, marks)
    }

    /// The cursor at `place`: the kind of the gesture while it runs, else the kind of the zone.
    public func cursor(at place: Place, _ context: GestureContext) -> TimelineCursor {
        switch state {
        case .moving: return .closedHand
        case .ranging: return .iBeam
        case .idle, .dropped, .pressed: break
        }
        guard case .lanes(let x, let y) = place else { return .arrow }
        return context.geometry.hit(x, y, in: context.session).cursor
    }

    private mutating func drag(_ place: Place, _ context: GestureContext) -> [GestureEffect] {
        guard case .lanes(let x, let y) = place else { return [] }
        let geometry = context.geometry
        switch state {
        case .idle, .dropped:
            return []
        case .pressed(let press):
            guard hypot(x - press.x, y - press.y) >= Self.threshold else { return [] }
            switch press.hit {
            case .move(let clip, let lane):
                guard context.canEdit else { return [] }
                let track = press.base.tracks[lane].id
                state = .moving(
                    press, Move(clip: clip, lane: lane, track: track, start: clip.start, preview: press.base))
                return drag(place, context)
            case .trim:
                // Slice 4 of the mouse-edits run: an edge drag trims. Until then the up is a click.
                return []
            case .range:
                state = .ranging(press)
                return drag(place, context)
            }
        case .moving(let press, var move):
            guard context.canEdit else {
                state = .dropped
                return []
            }
            let base = press.base
            let delta = geometry.frame(at: x) - press.frame
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
        case .ranging(let press):
            let marks = Marks.drag(
                from: press.frame, to: geometry.frame(at: x), lanes: (geometry.lane(at: press.y), geometry.lane(at: y)),
                in: context.session)
            return [.marks(marks)]
        }
    }

    /// A mouse-up under the threshold. On a clip: the clip range on its track, no seek. In the
    /// range zone (and every press with Shift or Command), the rules of decision 0017.
    private func click(_ press: Press, _ context: GestureContext) -> [GestureEffect] {
        switch press.hit {
        case .move(let clip, let lane), .trim(let clip, _, let lane):
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
    private func commit(_ press: Press, _ move: Move) -> [GestureEffect] {
        guard (move.track, move.start) != (press.base.tracks[move.lane].id, move.clip.start) else { return [] }
        let marks = Marks(inPoint: move.start, outPoint: move.start + move.clip.length, tracks: [move.track])
        return [.commit(GestureCommit(base: press.base, result: move.preview, marks: marks))]
    }
}
