import DirigibleCore
import Foundation

/// What the gesture reads at each event (decision 0020). `canEdit` is false while a take starts,
/// records, or finalizes. `canRipple` is false while a take is pending or split (decision 0037).
public struct GestureContext: Sendable {
    public var session: Session
    public var selection: Selection
    public var playhead: Frames
    public var geometry: LaneGeometry
    public var canEdit: Bool
    public var canRipple: Bool
    /// The device columns of one point (the backing scale): a ripple drag moves by whole columns,
    /// so the lanes can draw it by a shift (decision 0037).
    public var columnsPerPoint = 1.0
    public var dragMode = DragMode.overwrite
    /// True when a move, a trim, or a range drag snaps (decision 0020): the app preference is on and
    /// Command is not held at this event.
    public var snaps: Bool

    public init(
        session: Session, selection: Selection, playhead: Frames, geometry: LaneGeometry, canEdit: Bool,
        canRipple: Bool, snaps: Bool
    ) {
        (self.session, self.selection, self.playhead, self.geometry, self.canEdit, self.canRipple, self.snaps) =
            (session, selection, playhead, geometry, canEdit, canRipple, snaps)
    }

    /// The range of the selection; no points for a clip set.
    var marks: Marks { selection.rangeMarks(in: session) }
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
    case selection(Selection)
    case seek(Frames)
    /// The current marker of the window (decision 0018).
    case currentMarker(MarkerID)
    case commit(GestureCommit)
    /// A refused press: an Option press on a trim zone under a pending or split take (0037).
    case beep
    /// A No Overlap move drag stopped at a neighbor clip: VoiceOver says so once until the clip is
    /// free again.
    case stopAnnouncement
}

/// One Core edit on the session of the mouse-down (`base`), and the selection or the current
/// marker after it. Only the gesture makes one.
public struct GestureCommit: Equatable, Sendable {
    let base: Session
    let result: Session
    public let selection: Selection?
    public let marker: MarkerID?
    /// True for a ripple trim (decision 0037): the window passes it to `Studio.edit(ripple:)`.
    public let ripple: Bool

    init(base: Session, result: Session, selection: Selection?, marker: MarkerID?, ripple: Bool) {
        (self.base, self.result, self.selection, self.marker, self.ripple) = (base, result, selection, marker, ripple)
    }

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
