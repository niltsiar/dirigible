import DirigibleCore
import Foundation

/// The ruler part of the gesture (mouse-edits criteria 11 to 13): a flag drag moves a marker in
/// one undo entry, a triangle drag moves the in or the out point, and the time area seeks.
extension TimelineGesture {
    /// What a ruler mouse-down does.
    enum RulerDown {
        case none
        case seek(Frames)
        case press(Target)
    }

    /// A triangle, then a flag, then the time area (a seek at the down, as before the mouse-edits
    /// run). Left of the lanes: nothing.
    func rulerTarget(_ x: Double, _ y: Double, _ context: GestureContext) -> RulerDown {
        switch context.rulerHit(x, y) {
        case .none: .none
        case .time(let frame): .seek(frame)
        case .triangle(let point): .press(.point(point))
        case .flag(let id): context.session.markers[id].map { .press(.flag($0)) } ?? .none
        }
    }

    /// A flag drag event: the marker at its position at the down plus the movement, from 0 to
    /// `Frames.limit`. A take ends the drag.
    mutating func markerDrag(_ press: Press, _ original: Marker, _ x: Double, _ context: GestureContext)
        -> [GestureEffect]
    {
        guard context.canEdit else {
            state = .dropped
            return []
        }
        var moved = original
        let delta = press.delta(to: x, context.geometry)
        moved.position = min(max(.zero, original.position + delta), .limit)
        var preview = press.base
        // The clamp keeps the position in range, and the name is the saved one, so no input reaches
        // a throw. A throw keeps the last preview (decision 0020).
        guard (try? preview.setMarker(moved)) != nil else { return [] }
        state = .markerDrag(press, original, preview: preview)
        return []
    }

    /// A triangle drag event: the point at the down plus the movement. The in point stays before
    /// the out point and the out point after the in point, so the held triangle never changes.
    func pointDrag(_ press: Press, _ point: MarkPoint, _ x: Double, _ context: GestureContext) -> [GestureEffect] {
        let delta = press.delta(to: x, context.geometry)
        var marks = press.marks
        switch point {
        case .inPoint:
            guard let frame = marks.inPoint else { return [] }
            let high = marks.outPoint.map { $0 - Frames(1) } ?? .limit
            marks.inPoint = min(max(.zero, frame + delta), high)
        case .outPoint:
            guard let frame = marks.outPoint else { return [] }
            let low = marks.inPoint.map { $0 + Frames(1) } ?? .zero
            marks.outPoint = min(max(low, frame + delta), .limit)
        }
        return [.selection(.range(marks))]
    }

    /// A click on a flag makes it the current marker and seeks to it; a click on a triangle seeks
    /// to its point.
    func rulerClick(_ press: Press) -> [GestureEffect] {
        switch press.target {
        case .flag(let marker): [.currentMarker(marker.id), .seek(marker.position)]
        case .point(.inPoint): press.marks.inPoint.map { [.seek($0)] } ?? []
        case .point(.outPoint): press.marks.outPoint.map { [.seek($0)] } ?? []
        case .lane: []
        }
    }

    /// The mouse-up of a flag drag: one commit when the marker moved, and it becomes the current
    /// marker. A drag back to the start is a click.
    func commit(_ press: Press, _ original: Marker, _ preview: Session) -> [GestureEffect] {
        guard preview.markers[original.id]?.position != original.position else { return rulerClick(press) }
        return [.commit(GestureCommit(base: press.base, result: preview, selection: nil, marker: original.id))]
    }

    /// The frame and the flag under the ruler x `x`, for the ruler menu (criterion 13). A flag under
    /// a triangle counts. Nil left of the lanes.
    public static func menuTarget(at x: Double, _ context: GestureContext) -> (frame: Frames, marker: MarkerID?)? {
        let hit = RulerGeometry.hit(
            x, 0, markers: context.session.markers, marks: Marks(), geometry: context.geometry)
        switch hit {
        case .none: return nil
        case .flag(let id): return (context.geometry.frame(at: x), id)
        case .time, .triangle: return (context.geometry.frame(at: x), nil)
        }
    }
}

extension TimelineGesture.Target {
    /// True for a press that can start a session edit: a clip zone or a flag. A session change
    /// ends such a press, so its drag does not start on a stale session.
    var edits: Bool {
        switch self {
        case .lane(let hit): hit.clip != nil
        case .flag: true
        case .point: false
        }
    }
}

extension GestureContext {
    /// The range of the selection; no Marks for a clip set.
    var marks: Marks { selection.marks ?? Marks() }

    func rulerHit(_ x: Double, _ y: Double) -> RulerHit? {
        RulerGeometry.hit(x, y, markers: session.markers, marks: marks, geometry: geometry)
    }
}
