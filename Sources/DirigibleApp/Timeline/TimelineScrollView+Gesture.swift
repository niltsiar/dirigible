import AppKit
import DirigibleCore
import DirigibleTimeline

/// The gesture questions of the window: the hit view, the cursor, and the ruler menu (decision 0020).
extension TimelineScrollView {
    /// The lanes take a mouse event in the shown part of the clip view under the last lane, inside
    /// the width of the lanes, so the gesture gets that point (K20: a double-click there clears the
    /// selection). The gap of an overscroll above lane 0 or left of x 0 stays with the clip view.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        let lanePoint = lanes.convert(point, from: superview)
        guard hit === contentView, shown.contains(lanePoint), lanePoint.y >= lanes.bounds.maxY,
            lanePoint.x >= lanes.bounds.minX, lanePoint.x < lanes.bounds.maxX
        else { return hit }
        return lanes
    }

    /// The cursor of the gesture at a lane or ruler point; `flags` are the modifier keys now.
    func cursor(at place: Place, flags: NSEvent.ModifierFlags = []) -> TimelineCursor {
        guard let source, let context = context(source) else { return .arrow }
        return gesture.cursor(
            at: place, context, option: flags.contains(.option), shift: flags.contains(.shift),
            command: flags.contains(.command))
    }

    /// The frame and the flag of the ruler menu at the document x `x`. Nil during a gesture, so a
    /// right-click does not open a menu over a drag (mouse-edits Q10).
    func menuTarget(at x: Double) -> (frame: Frames, marker: MarkerID?)? {
        guard !gesture.isActive, let source, let context = context(source) else { return nil }
        return TimelineGesture.menuTarget(at: x, context)
    }

    /// What the gesture reads at each event (decision 0020).
    func context(_ inputs: LaneInputs) -> GestureContext? {
        guard let model, let studio, let geometry = inputs.geometry else { return nil }
        // One predicate for every ripple entry point (decision 0037): a pending or split take.
        var context = GestureContext(
            session: inputs.session, selection: model.timeline.selection, playhead: studio.playhead, geometry: geometry,
            canEdit: model.canEdit,
            canRipple: studio.canRipple, snaps: model.snaps && !lanes.commandHeld)
        context.columnsPerPoint = Double(window?.backingScaleFactor ?? 2)
        return context
    }
}
