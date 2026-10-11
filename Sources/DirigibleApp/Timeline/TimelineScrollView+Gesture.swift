import AppKit
import DirigibleCore
import DirigibleTimeline

/// The gesture questions of the window: the cursor and the ruler menu (decision 0020).
extension TimelineScrollView {
    /// The cursor of the gesture at a lane or ruler point; `option` is the state of the Option key.
    func cursor(at place: Place, option: Bool = false) -> TimelineCursor {
        guard let source, let context = context(source) else { return .arrow }
        return gesture.cursor(at: place, context, option: option)
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
            canRipple: studio.canRipple)
        context.columnsPerPoint = Double(window?.backingScaleFactor ?? 2)
        context.snaps = model.app?.snaps != false && !lanes.commandHeld
        return context
    }
}
