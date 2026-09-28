import AppKit
import DirigibleCore
import DirigibleTimeline

/// The zoom and the scroll of the lanes: the menu keys, Command-wheel and pinch zoom at the
/// pointer, and the first fit.
extension TimelineScrollView {
    /// The part in view, or nil before the first update with a width.
    var viewport: Viewport? {
        guard let source, shown.width > 0 else { return nil }
        return Viewport(
            scale: source.scale, origin: Double(shown.minX) * source.scale.framesPerPoint, width: Double(shown.width),
            end: source.session.end, rate: source.session.sampleRate)
    }

    /// The one entry of every zoom and scroll input (decision 0025). A scroll holds the follow
    /// during play (0017); during a lane gesture no input changes the scale.
    func navigate(_ input: NavigationInput) {
        guard let viewport, let studio else { return }
        let context = NavigationContext(viewport: viewport, playhead: studio.playhead, holdsScale: gesture.isActive)
        guard let target = navigation.handle(input, context) else { return }
        if input.scrolls { userScrolled() }
        show(target.scale, origin: target.origin)
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

    /// The fit at open goes past the navigation, so it makes no history entry.
    func fitOnce() {
        guard !fitted, let fit = viewport?.fit else { return }
        fitted = true
        show(fit.scale, origin: fit.origin)
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
        navigate(.zoom(by: pow(2, event.hasPreciseScrollingDeltas ? -dy / 40 : -dy), at: pointer(event)))
    }

    override func magnify(with event: NSEvent) {
        navigate(.zoom(by: 1 - Double(event.magnification), at: pointer(event)))
    }

    func pointer(_ event: NSEvent) -> Double {
        Double(contentView.convert(event.locationInWindow, from: nil).x - shown.minX)
    }
}
