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
}
