import AppKit
import DirigibleCore
import DirigibleTimeline

/// The zoom and the scroll of the lanes: the menu keys, Command-wheel and pinch zoom at the
/// pointer, and the first fit.
extension TimelineScrollView {
    /// The zoom by `factor` at `x` points from the left edge (the pointer), or with no `x` at the
    /// anchor of the keys: the playhead when it is in view, else the view center.
    func zoom(by factor: Double, at x: Double? = nil) {
        guard let inputs = source, let studio else { return }
        let width = Double(shown.width)
        let anchor =
            x.map { (frame: Frames(Int(origin + $0 * framesPerPoint)), x: $0) }
            ?? zoomAnchor(playhead: studio.playhead, origin: origin, width: width, scale: inputs.scale)
        let zoomed = inputs.scale.zoomed(by: factor, anchor: anchor.frame, at: anchor.x, limits: limits(inputs))
        show(zoomed.scale, origin: zoomed.origin)
    }

    /// Zoom to Session: 0 to the end + 2%.
    func zoomToSession() {
        guard let inputs = source else { return }
        let end = inputs.session.end
        show(TimelineScale.fit(end: end, width: Double(shown.width), limits: limits(inputs)), origin: 0)
    }

    /// Zoom to Selection: the range with 5% on each side. With no selection, nothing.
    func zoomToSelection() {
        guard let inputs = source, let selection = model?.timeline.marks.selection(in: inputs.session) else {
            return
        }
        let fit = TimelineScale.fit(selection.range, width: Double(shown.width), limits: limits(inputs))
        show(fit.scale, origin: fit.origin)
    }

    func limits(_ inputs: LaneInputs) -> ClosedRange<Double> {
        TimelineScale.limits(
            end: inputs.session.end, rate: inputs.session.sampleRate, width: Double(shown.width))
    }

    /// Sets the scale here and in the window model, then scrolls: the document view has its new
    /// width before the scroll, and the SwiftUI update after it gives equal inputs.
    func show(_ scale: TimelineScale, origin: Double) {
        guard var inputs = source else { return }
        if model?.timeline.scale != scale { model?.timeline.scale = scale }
        inputs.scale = scale
        update(inputs)
        scroll(toFrame: origin)
    }

    func fitOnce() {
        guard !fitted, source != nil, shown.width > 0 else { return }
        fitted = true
        zoomToSession()
    }

    /// Automatic Scroll turned on: the page of the playhead, with the playhead at 11%.
    func showPlayhead() {
        guard let studio,
            let turn = followOrigin(
                playhead: studio.playhead, origin: origin, frames: visibleFrames, direction: .forward)
        else { return }
        scroll(toFrame: turn)
    }

    /// A horizontal scroll that puts `origin` at the left edge of the lanes in view. The vertical
    /// origin stays.
    func scroll(toFrame origin: Double) {
        contentView.scroll(
            to: NSPoint(x: origin / framesPerPoint - contentView.contentInsets.left, y: contentView.bounds.minY))
        reflectScrolledClipView(contentView)
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else {
            super.scrollWheel(with: event)
            userScrolled()
            return
        }
        let dy = Double(event.scrollingDeltaY)
        zoom(by: pow(2, event.hasPreciseScrollingDeltas ? -dy / 40 : -dy), at: pointer(event))
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 - Double(event.magnification), at: pointer(event))
    }

    func pointer(_ event: NSEvent) -> Double {
        Double(contentView.convert(event.locationInWindow, from: nil).x - shown.minX)
    }
}
