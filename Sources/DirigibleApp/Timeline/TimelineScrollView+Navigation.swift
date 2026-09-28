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
        guard let viewport, let studio, let model else { return }
        let context = NavigationContext(viewport: viewport, playhead: studio.playhead, holdsScale: gesture.isActive)
        let target = model.navigation.handle(input, context)
        let navigation = model.navigation
        if model.timeline.canGoBack != navigation.canGoBack || model.timeline.canGoForward != navigation.canGoForward {
            (model.timeline.canGoBack, model.timeline.canGoForward) = (navigation.canGoBack, navigation.canGoForward)
        }
        guard let target else { return }
        if input.scrolls { userScrolled() }
        show(target.scale, origin: target.origin)
        // VoiceOver hears a discrete input or the end of a stroke, not each event of a drag (U15).
        guard !overviewGesture.isActive, !gesture.isActive else { return }
        switch input.stroke {
        case nil, .ended, .cancelled, .momentum(ended: true): overview?.valueChanged()
        case .wheel: overview?.valueChangedLater()
        case .began, .changed, .momentum(ended: false): break
        }
    }

    /// Smart zoom at the lane point `point` (U11): the clip under it, or 8x, or the fit.
    func smartZoom(at point: NSPoint) {
        guard let source, source.laneHeight > 0 else { return }
        let lane = Int(max(0, point.y) / source.laneHeight)
        let frame = Frames(Int(max(0, point.x) * source.scale.framesPerPoint))
        let clips = lane < source.session.tracks.count ? source.session.tracks[lane].clips : nil
        let clip = clips.flatMap { clips in clips.index(holding: frame).map { clips[$0].range } }
        navigate(.smartZoom(at: Double(point.x - shown.minX), clip: clip))
    }

    /// A mouse event of the overview strip: the gesture gives the input of the navigation.
    func overviewEvent(_ event: OverviewEvent) {
        guard let viewport, let strip = overview else { return }
        let geometry = OverviewGeometry(width: Double(strip.bounds.width), end: viewport.end, rate: viewport.rate)
        if let input = overviewGesture.handle(event, geometry, viewport) { navigate(input) }
    }

    /// Esc: true when an overview drag ran and Esc ended it.
    func cancelOverview() -> Bool {
        guard overviewGesture.isActive else { return false }
        overviewEvent(.escape)
        return true
    }

    /// The cursor of the overview gesture at the strip x `x`.
    func overviewCursor(at x: Double) -> TimelineCursor {
        guard let viewport, let strip = overview else { return .arrow }
        let geometry = OverviewGeometry(width: Double(strip.bounds.width), end: viewport.end, rate: viewport.rate)
        return overviewGesture.cursor(at: x, geometry, viewport)
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

    /// The first view of the pane: the last view of the window, else the fit at open. It goes past
    /// the navigation, so it makes no history entry (code gate 2 item 4).
    func fitOnce() {
        guard !fitted, let viewport else { return }
        fitted = true
        let first = model?.shownZoom.map(viewport.clamped) ?? viewport.fit
        show(first.scale, origin: first.origin)
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
        let stroke = Stroke(
            phase: WheelPhase(event.phase), momentum: WheelPhase(event.momentumPhase), time: event.timestamp)
        navigate(
            .zoom(
                by: pow(2, event.hasPreciseScrollingDeltas ? -dy / 40 : -dy), at: pointer(event), stroke: stroke,
                wheel: event.timestamp))
    }

    override func magnify(with event: NSEvent) {
        let stroke = Stroke(phase: WheelPhase(event.phase), momentum: .none, time: event.timestamp)
        navigate(.zoom(by: 1 - Double(event.magnification), at: pointer(event), stroke: stroke))
    }

    /// A two-finger double tap (U11).
    override func smartMagnify(with event: NSEvent) {
        smartZoom(at: lanes.convert(event.locationInWindow, from: nil))
    }

    func pointer(_ event: NSEvent) -> Double {
        Double(contentView.convert(event.locationInWindow, from: nil).x - shown.minX)
    }
}

extension WheelPhase {
    /// The phase of an event: a pinch or a wheel event of a trackpad. May-begin and stationary
    /// count as changed.
    init(_ phase: NSEvent.Phase) {
        if phase.isEmpty {
            self = .none
        } else if phase.contains(.began) {
            self = .began
        } else if phase.contains(.ended) {
            self = .ended
        } else if phase.contains(.cancelled) {
            self = .cancelled
        } else {
            self = .changed
        }
    }
}
