import DirigibleCore
import Foundation

/// A scale and a left edge: the part of the timeline that a view shows.
public struct Zoom: Equatable, Sendable {
    public var scale: TimelineScale
    /// The frame at the left edge.
    public var origin: Double

    public init(scale: TimelineScale, origin: Double) {
        (self.scale, self.origin) = (scale, origin)
    }

    /// The same frames per point, and origins within 1 pt at this scale.
    func matches(_ other: Zoom) -> Bool {
        scale == other.scale && abs(origin - other.origin) <= scale.framesPerPoint
    }
}

/// The part of the timeline in view (decision 0025). The clip view owns the origin, so this value
/// is derived at each read and never stored.
public struct Viewport: Equatable, Sendable {
    public var scale: TimelineScale
    /// The frame at the left edge.
    public var origin: Double
    /// The width of the lanes in view, in points.
    public var width: Double
    public var end: Frames
    public var rate: Int

    public init(scale: TimelineScale, origin: Double, width: Double, end: Frames, rate: Int) {
        (self.scale, self.origin, self.width, self.end, self.rate) = (scale, origin, width, end, rate)
    }

    public var zoom: Zoom { Zoom(scale: scale, origin: origin) }
    /// The frames in view.
    public var frames: Double { width * scale.framesPerPoint }
    /// Zoom to Session: 0 to the end + 2%.
    public var fit: Zoom { Zoom(scale: TimelineScale.fit(end: end, width: width, limits: limits), origin: 0) }
    var limits: ClosedRange<Double> { TimelineScale.limits(end: end, rate: rate, width: width) }
    /// The place of the view from 0 (the start) to 1 (the last page): origin / (extent - frames in
    /// view), 0 when that is 0 or less (the fit), clamped to 0...1 (U15).
    public var position: Double {
        let range = Self.extent(end: end, rate: rate) - frames
        guard range > 0 else { return 0 }
        return min(max(origin / range, 0), 1)
    }

    /// The one width of the lanes: max(end, 10 s) + 2% at the zoom, in whole points, and at least
    /// `shown`. With a part of a point, AppKit moved the clip bounds by 1 pt when a wider header made
    /// the lanes narrower (run 1b slice 1). The 2% holds the half point.
    public static func documentWidth(end: Frames, rate: Int, scale: TimelineScale, shown: Double) -> Double {
        max((extent(end: end, rate: rate) / scale.framesPerPoint).rounded(), shown)
    }

    /// The frames of the whole timeline: max(end, 10 s) + 2%, as Zoom to Session.
    public static func extent(end: Frames, rate: Int) -> Double { Double(max(end.count, 10 * rate)) * 1.02 }

    /// The scale in the zoom limits, and the origin from 0 to the last page at that scale.
    func clamped(_ zoom: Zoom) -> Zoom {
        let points = min(max(zoom.scale.framesPerPoint, limits.lowerBound), limits.upperBound)
        let scale = TimelineScale(framesPerPoint: points)
        let last = (Self.documentWidth(end: end, rate: rate, scale: scale, shown: width) - width) * points
        return Zoom(scale: scale, origin: min(max(zoom.origin, 0), max(0, last)))
    }
}

/// The phase of one continuous zoom input: a pinch, a wheel burst, or an overview edge drag.
public enum Stroke: Equatable, Sendable {
    case began, changed, ended
    /// A momentum event after the end of a stroke; `ended` at the end of the momentum.
    case momentum(ended: Bool)
    /// Esc of an overview edge drag: the history goes back to its state before the began.
    case cancelled
    /// A mouse wheel event with no phase, at `time` seconds.
    case wheel(time: Double)
}

/// The phase or the momentum phase of a wheel or pinch event; the app parses `NSEvent` into it.
public enum WheelPhase: Sendable { case none, began, changed, ended, cancelled }

extension Stroke {
    /// Plan gate item 6: a momentum event continues the stroke, and the end of the momentum ends
    /// it; an event with no phase and no momentum is a mouse wheel event. A system cancel of a
    /// pinch keeps the zoom, so it is an end.
    public init(phase: WheelPhase, momentum: WheelPhase, time: Double) {
        switch (phase, momentum) {
        case (.began, _): self = .began
        case (.changed, _): self = .changed
        case (.ended, _), (.cancelled, _): self = .ended
        case (.none, .none): self = .wheel(time: time)
        case (.none, .ended), (.none, .cancelled): self = .momentum(ended: true)
        case (.none, .began), (.none, .changed): self = .momentum(ended: false)
        }
    }
}

/// One input that changes the part of the timeline in view (decision 0025).
public enum NavigationInput: Equatable, Sendable {
    public enum Direction: Equatable, Sendable { case backward, forward }

    /// The scale times `by` at `at` points from the left edge (the pointer), or with no `at` at the
    /// anchor of the keys (0017). `wheel`: the time of a wheel event, momentum included.
    case zoom(by: Double, at: Double? = nil, stroke: Stroke? = nil, wheel: Double? = nil)
    case fitSession
    /// H: the fit of the range, or of the session with no range; again with the view unchanged,
    /// the view before (U3).
    case toggleSelection(Range<Frames>?)
    /// Smart zoom at `at` points from the left edge, with the range of the clip under the pointer
    /// (U11).
    case smartZoom(at: Double, clip: Range<Frames>?)
    case back, forward
    /// One view left or right with a 10% overlap.
    case page(Direction)
    /// The frame in the middle of the view.
    case center(Frames)
    /// The frame at the left edge.
    case scroll(to: Double)
    case zoomTo(Zoom, stroke: Stroke)
    /// A double-click on the overview: the fit of the session, and the view `before` the first
    /// click of the double-click again (U10).
    case toggleFit(before: Zoom)

    /// True for an input that moves the view and keeps the scale: it holds the follow (0017).
    public var scrolls: Bool {
        switch self {
        case .page, .center, .scroll: true
        case .zoom, .fitSession, .toggleSelection, .smartZoom, .back, .forward, .zoomTo, .toggleFit: false
        }
    }

    /// The stroke of a continuous input; nil for a discrete input.
    public var stroke: Stroke? {
        switch self {
        case .zoom(_, _, let stroke, _): stroke
        case .zoomTo(_, let stroke): stroke
        default: nil
        }
    }
}

public struct NavigationContext: Sendable {
    public var viewport: Viewport
    public var playhead: Frames
    /// True during a lane gesture: the lanes keep their width, so no input changes the scale.
    public var holdsScale: Bool

    public init(viewport: Viewport, playhead: Frames, holdsScale: Bool) {
        (self.viewport, self.playhead, self.holdsScale) = (viewport, playhead, holdsScale)
    }
}

/// The navigation of one window: an input and the view in, the view to show out. It keeps the
/// zoom history (F83) and the toggle memory; the clip view keeps the current view.
public struct Navigation: Sendable {
    /// ponytail: 50 entries, not saved (Q5).
    static let depth = 50
    /// A wheel burst ends after this gap in seconds (a calibration value).
    public static let wheelGap = 0.5

    private var back: [Zoom] = []
    private var forward: [Zoom] = []
    /// The view before a toggle and the view that the toggle showed (U3, U10).
    private var toggle: (from: Zoom, to: Zoom)?
    /// The stroke of the last entry: closed, open from its began to its end, or ended with its
    /// momentum still to come. Any input that does not continue it closes it (code gate 1 item 5).
    private enum StrokeState { case closed, open, ended }
    private var strokeState = StrokeState.closed
    /// The history before the open stroke, for Esc (code gate 1 item 4).
    private var beforeStroke: (back: [Zoom], forward: [Zoom])?
    private var lastWheel: Double?

    public init() {}

    /// The Zoom Back and Zoom Forward items are dimmed with no step (U5).
    public var canGoBack: Bool { !back.isEmpty }
    public var canGoForward: Bool { !forward.isEmpty }

    /// The view to show, clamped, or nil for no change. Only this function changes the history
    /// and the toggle memory.
    public mutating func handle(_ input: NavigationInput, _ context: NavigationContext) -> Zoom? {
        if context.holdsScale, !input.scrolls { return nil }
        let view = context.viewport
        let current = view.zoom
        let fit = view.clamped(view.fit)
        var entry: Zoom? = current
        let target: Zoom
        switch input {
        case .zoom(let factor, let x, let stroke, let wheel):
            let anchor =
                x.map { (frame: Frames(Int(view.origin + $0 * view.scale.framesPerPoint)), x: $0) }
                ?? zoomAnchor(playhead: context.playhead, origin: view.origin, width: view.width, scale: view.scale)
            let zoomed = view.scale.zoomed(by: factor, anchor: anchor.frame, at: anchor.x, limits: view.limits)
            target = Zoom(scale: zoomed.scale, origin: zoomed.origin)
            if !strokePushes(stroke) { entry = nil }
            if let wheel { lastWheel = wheel }
        case .fitSession: target = fit
        case .toggleSelection(let range):
            let selection = range.map { TimelineScale.fit($0, width: view.width, limits: view.limits) }
            target = toggled(
                to: selection.map { view.clamped(Zoom(scale: $0.scale, origin: $0.origin)) } ?? fit, current)
        case .smartZoom(let x, let clip):
            if !current.matches(fit) {
                target = fit
            } else if let clip {
                let zoom = TimelineScale.fit(clip, width: view.width, limits: view.limits)
                target = Zoom(scale: zoom.scale, origin: zoom.origin)
            } else {
                let frame = Frames(Int(view.origin + x * view.scale.framesPerPoint))
                let zoomed = view.scale.zoomed(by: 1.0 / 8, anchor: frame, at: x, limits: view.limits)
                target = Zoom(scale: zoomed.scale, origin: zoomed.origin)
            }
        case .back, .forward:
            guard let step = input == .back ? Self.pop(&back, current) : Self.pop(&forward, current) else { return nil }
            if input == .back { forward.append(current) } else { back.append(current) }
            closeStroke()
            return view.clamped(step)
        case .page(let direction):
            let step = 0.9 * view.frames
            target = Zoom(scale: view.scale, origin: view.origin + (direction == .forward ? step : -step))
        case .center(let frame): target = Zoom(scale: view.scale, origin: Double(frame.count) - view.frames / 2)
        case .scroll(let origin): target = Zoom(scale: view.scale, origin: origin)
        case .zoomTo(let zoom, let stroke):
            target = zoom
            if !strokePushes(stroke) { entry = nil }
        case .toggleFit(let before):
            target = toggled(to: fit, before)
            entry = target.matches(fit) ? before : current
        }
        let shown = view.clamped(target)
        if input.scrolls { return shown }
        if shown.matches(current) {
            // An input that would make an entry and changes nothing ends the stroke before it and
            // opens no stroke: the next stroke event that changes the view makes the entry (code
            // gate 2 item 3). An event that continues a stroke keeps it.
            if entry != nil { closeStroke() }
            return nil
        }
        if input.stroke == nil { closeStroke() }
        if let entry { push(entry) }
        return shown
    }

    /// The target of a toggle: `target`, or the view before the last toggle when `before` is still
    /// the view that the toggle showed. `before` is the current view, or for a double-click the
    /// view at its first click.
    private mutating func toggled(to target: Zoom, _ before: Zoom) -> Zoom {
        if let toggle, before.matches(target), toggle.to.matches(target) {
            self.toggle = nil
            return toggle.from
        }
        toggle = (before, target)
        return target
    }

    /// True when the stroke makes an entry: a began, a changed or ended with no open stroke (a
    /// lost began), momentum with no stroke, or a wheel event after a gap. Only momentum continues
    /// an ended stroke or a wheel burst. A cancelled stroke puts back the history before it.
    private mutating func strokePushes(_ stroke: Stroke?) -> Bool {
        let state = strokeState
        switch stroke {
        case nil: return true
        case .began, .changed, .ended:
            let pushes = stroke == .began || state != .open
            if pushes { beforeStroke = (back, forward) }
            strokeState = stroke == .ended ? .ended : .open
            lastWheel = nil
            return pushes
        case .momentum:
            if state == .closed { strokeState = .ended }
            return state == .closed
        case .cancelled:
            if let beforeStroke { (back, forward) = beforeStroke }
            closeStroke()
            return false
        case .wheel(let time):
            strokeState = .ended
            beforeStroke = nil
            return lastWheel.map { time - $0 > Self.wheelGap } ?? true
        }
    }

    /// A discrete input or a cancel: the next stroke or wheel event makes its own entry.
    private mutating func closeStroke() {
        strokeState = .closed
        beforeStroke = nil
        lastWheel = nil
    }

    private mutating func push(_ zoom: Zoom) {
        back.append(zoom)
        if back.count > Self.depth { back.removeFirst() }
        forward = []
    }

    /// The last entry that is not the current view; the entries that match it go.
    private static func pop(_ stack: inout [Zoom], _ current: Zoom) -> Zoom? {
        while let last = stack.popLast() {
            if !last.matches(current) { return last }
        }
        return nil
    }
}

/// The anchor of the zoom keys: the playhead when it is in the view, else the view center.
/// `origin` is the frame at the left edge; `width` is in points.
func zoomAnchor(playhead: Frames, origin: Double, width: Double, scale: TimelineScale) -> (frame: Frames, x: Double) {
    let x = (Double(playhead.count) - origin) / scale.framesPerPoint
    if x >= 0, x < width { return (playhead, x) }
    return (Frames(Int(origin + width / 2 * scale.framesPerPoint)), width / 2)
}
