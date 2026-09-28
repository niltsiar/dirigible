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
    case wheel(time: Double)
}

/// One input that changes the part of the timeline in view (decision 0025).
public enum NavigationInput: Equatable, Sendable {
    public enum Direction: Equatable, Sendable { case backward, forward }

    /// The scale times `by` at `at` points from the left edge (the pointer), or with no `at` at the
    /// anchor of the keys (0017).
    case zoom(by: Double, at: Double? = nil, stroke: Stroke? = nil)
    case fitSession
    /// Zoom to Selection: the fit of the range; nothing with no range.
    case toggleSelection(Range<Frames>?)
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
        case .zoom, .fitSession, .toggleSelection, .zoomTo, .toggleFit: false
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

/// The navigation of one window: an input and the view in, the view to show out.
public struct Navigation: Sendable {
    public init() {}

    /// The view to show, clamped, or nil for no change.
    public mutating func handle(_ input: NavigationInput, _ context: NavigationContext) -> Zoom? {
        let view = context.viewport
        let target: Zoom
        switch input {
        case .zoom(let factor, let x, _):
            let anchor =
                x.map { (frame: Frames(Int(view.origin + $0 * view.scale.framesPerPoint)), x: $0) }
                ?? zoomAnchor(playhead: context.playhead, origin: view.origin, width: view.width, scale: view.scale)
            let zoomed = view.scale.zoomed(by: factor, anchor: anchor.frame, at: anchor.x, limits: view.limits)
            target = Zoom(scale: zoomed.scale, origin: zoomed.origin)
        case .fitSession: target = view.fit
        case .toggleSelection(let range):
            guard let range else { return nil }
            let fit = TimelineScale.fit(range, width: view.width, limits: view.limits)
            target = Zoom(scale: fit.scale, origin: fit.origin)
        case .page(let direction):
            let step = 0.9 * view.frames
            target = Zoom(scale: view.scale, origin: view.origin + (direction == .forward ? step : -step))
        case .center(let frame): target = Zoom(scale: view.scale, origin: Double(frame.count) - view.frames / 2)
        case .scroll(let origin): target = Zoom(scale: view.scale, origin: origin)
        case .zoomTo(let zoom, _): target = zoom
        case .toggleFit: return nil
        }
        if context.holdsScale, !input.scrolls { return nil }
        return view.clamped(target)
    }
}

/// The anchor of the zoom keys: the playhead when it is in the view, else the view center.
/// `origin` is the frame at the left edge; `width` is in points.
func zoomAnchor(playhead: Frames, origin: Double, width: Double, scale: TimelineScale) -> (frame: Frames, x: Double) {
    let x = (Double(playhead.count) - origin) / scale.framesPerPoint
    if x >= 0, x < width { return (playhead, x) }
    return (Frames(Int(origin + width / 2 * scale.framesPerPoint)), width / 2)
}
