import DirigibleCore
import Foundation

/// The overview strip across the timeline pane (decision 0025): the whole session, max(end, 10 s)
/// + 2% as Zoom to Session, over the strip width.
public struct OverviewGeometry: Equatable, Sendable {
    public static let height = 28.0
    /// The narrowest view frame that the strip draws, in points.
    static let frameMinimum = 6.0
    /// The narrowest view frame with edge zones (U9); a narrower frame is all body.
    public static let edgeMinimum = 16.0
    /// The reach of an edge zone outside and inside the frame.
    static let edgeOut = 3.0
    static let edgeIn = 3.0

    public let width: Double
    public let framesPerPoint: Double

    public init(width: Double, end: Frames, rate: Int) {
        self.width = width
        framesPerPoint = Viewport.extent(end: end, rate: rate) / max(1, width)
    }

    /// The frame at `x`; an x before 0 gives frame 0.
    public func frame(at x: Double) -> Frames { Frames(Int(max(0, x) * framesPerPoint)) }
    public func x(of frame: Frames) -> Double { Double(frame.count) / framesPerPoint }

    /// The view frame of `view`: at least 6 pt wide, on its true center.
    public func viewFrame(_ view: Viewport) -> Rect {
        let (low, high) = (view.origin / framesPerPoint, (view.origin + view.frames) / framesPerPoint)
        let width = max(high - low, Self.frameMinimum)
        return Rect(x: (low + high - width) / 2, y: 0, width: width, height: Self.height)
    }

    func hit(_ x: Double, _ view: Viewport) -> OverviewHit {
        let frame = viewFrame(view)
        if frame.width >= Self.edgeMinimum {
            if x >= frame.minX - Self.edgeOut, x < frame.minX + Self.edgeIn { return .leadingEdge }
            if x > frame.maxX - Self.edgeIn, x <= frame.maxX + Self.edgeOut { return .trailingEdge }
        }
        return x >= frame.minX && x <= frame.maxX ? .body : .outside
    }
}

enum OverviewHit: Equatable, Sendable { case leadingEdge, trailingEdge, body, outside }

/// Every value that the strip image draws: its render key. A new drawn value needs a place here,
/// else an edit leaves an old strip on the screen (decision 0025).
public struct OverviewInputs: Equatable, Sendable {
    public var lanes: [ClipLane]
    /// By position.
    public var markers: [Marker]
    public var selection: Range<Frames>?
    public var selectedLanes: [Int]
    /// The frames of the strip width: `Viewport.extent`.
    public var extent: Double

    public init(session: Session, selection: Range<Frames>?, selectedLanes: [Int], extent: Double) {
        lanes = session.tracks.map(\.clips)
        markers = session.sortedMarkers
        (self.selection, self.selectedLanes, self.extent) = (selection, selectedLanes, extent)
    }
}

/// A marker or chapter line of the strip: its pixel column and pixel rows from the top.
public struct OverviewTick: Equatable, Sendable {
    public var column: Int
    public var kind: Marker.Kind
    public var rows: Range<Int>
}

/// What the strip paints, in pixel columns and rows (U7, plan gate item 7).
public struct OverviewPlan: Equatable, Sendable {
    /// The pixel rows of each strip row, from the top.
    public var rows: [Range<Int>]
    /// The merged column spans of each strip row.
    public var clips: [[Range<Int>]]
    public var ticks: [OverviewTick]
    public var band: Range<Int>?
    /// The strip rows of the selected lanes.
    public var tinted: [Int]

    /// At most one row per 2 px; more tracks merge into the rows in order. A 1 px gap between rows
    /// only when each row keeps 2 px with it. A clip covers the columns that its frames touch, at
    /// least one, and spans that touch merge.
    public init(_ inputs: OverviewInputs, columns: Int, height: Int) {
        let tracks = inputs.lanes.count
        let count = min(tracks, height / 2)
        let gap = count > 1 && (height - (count - 1)) / count >= 2 ? 1 : 0
        let rowHeight = count > 0 ? (height - (count - 1) * gap) / count : 0
        rows = (0..<count).map { $0 * (rowHeight + gap)..<$0 * (rowHeight + gap) + rowHeight }
        let perColumn = Double(columns) / max(1, inputs.extent)
        func column(_ frame: Frames) -> Int { Int((Double(frame.count) * perColumn).rounded(.down)) }
        // A range of one frame or more always reaches past the column of its start.
        func span(_ range: Range<Frames>) -> Range<Int> {
            column(range.lowerBound)..<Int((Double(range.upperBound.count) * perColumn).rounded(.up))
        }
        func row(_ lane: Int) -> Int { lane * count / max(1, tracks) }
        var spans = [[Range<Int>]](repeating: [], count: count)
        for (lane, clips) in inputs.lanes.enumerated() where count > 0 {
            spans[row(lane)] += clips.map { span($0.range) }
        }
        clips = spans.map { row in
            row.sorted { $0.lowerBound < $1.lowerBound }.reduce(into: []) { merged, span in
                if let last = merged.last, span.lowerBound <= last.upperBound {
                    merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, span.upperBound)
                } else {
                    merged.append(span)
                }
            }
        }
        ticks = inputs.markers.map { marker in
            let length = marker.kind == .chapter ? height / 2 : height / 4
            return OverviewTick(
                column: column(marker.position), kind: marker.kind, rows: 0..<length)
        }
        band = inputs.selection.map(span)
        tinted = Array(Set(inputs.selectedLanes.filter { $0 < tracks }.map(row))).sorted()
    }
}

/// A mouse event of the strip, in strip points.
public enum OverviewEvent: Equatable, Sendable {
    case down(x: Double, clicks: Int)
    case drag(x: Double)
    case up(x: Double)
    case escape
}

/// The mouse gesture of the strip: the states x events table of the run design (decision 0025).
/// A drag starts after 3 pt (0020).
public struct OverviewGesture: Sendable {
    static let threshold = 3.0

    struct Press: Sendable {
        var x: Double
        var hit: OverviewHit
        /// The view at the mouse-down.
        var zoom: Zoom
    }

    enum State: Sendable {
        case idle
        case pressed(Press)
        /// `grab`: the frames from the left edge of the view to the pointer.
        case scrolling(Press, grab: Double)
        /// `fixed`: the frame of the edge that stays.
        case resizing(Press, fixed: Double)
    }

    var state = State.idle
    /// The view at the last single-click press: the view before a double-click (plan gate item 1).
    var firstClick: Zoom?

    public init() {}

    public var isActive: Bool {
        if case .idle = state { return false }
        return true
    }

    /// The input of `event` for the navigation, or nil.
    public mutating func handle(_ event: OverviewEvent, _ strip: OverviewGeometry, _ view: Viewport) -> NavigationInput?
    {
        switch (state, event) {
        case (_, .down(_, let clicks)) where clicks >= 2:
            state = .idle
            return .toggleFit(before: firstClick ?? view.zoom)
        case (_, .down(let x, _)):
            firstClick = view.zoom
            let press = Press(x: x, hit: strip.hit(x, view), zoom: view.zoom)
            guard press.hit == .outside else {
                state = .pressed(press)
                return nil
            }
            state = .scrolling(press, grab: view.frames / 2)
            return .center(strip.frame(at: x))
        case (.pressed(let press), .drag(let x)):
            guard abs(x - press.x) >= Self.threshold else { return nil }
            if press.hit == .body {
                state = .scrolling(press, grab: press.x * strip.framesPerPoint - press.zoom.origin)
                return handle(event, strip, view)
            }
            let span = press.zoom.scale.framesPerPoint * view.width
            state = .resizing(press, fixed: press.hit == .leadingEdge ? press.zoom.origin + span : press.zoom.origin)
            return resize(to: x, stroke: .began, strip, view)
        case (.pressed, .up(let x)):
            state = .idle
            return .center(strip.frame(at: x))
        case (.scrolling(_, let grab), .drag(let x)):
            return .scroll(to: x * strip.framesPerPoint - grab)
        case (.scrolling(_, let grab), .up(let x)):
            state = .idle
            return .scroll(to: x * strip.framesPerPoint - grab)
        case (.scrolling(let press, _), .escape):
            state = .idle
            return .scroll(to: press.zoom.origin)
        case (.resizing, .drag(let x)):
            return resize(to: x, stroke: .changed, strip, view)
        case (.resizing, .up(let x)):
            defer { state = .idle }
            return resize(to: x, stroke: .ended, strip, view)
        case (.resizing(let press, _), .escape):
            state = .idle
            return .zoomTo(press.zoom, stroke: .cancelled)
        case (.pressed, .escape):
            state = .idle
            return nil
        case (.idle, _), (_, .drag), (_, .up), (_, .escape):
            return nil
        }
    }

    /// The zoom with the moving edge at `x` and the fixed edge in place. The moving edge stops at
    /// the fixed edge plus the closest zoom.
    private func resize(to x: Double, stroke: Stroke, _ strip: OverviewGeometry, _ view: Viewport) -> NavigationInput? {
        guard case .resizing(let press, let fixed) = state else { return nil }
        let (moving, least) = (x * strip.framesPerPoint, view.limits.lowerBound * view.width)
        let (low, high) =
            press.hit == .leadingEdge ? (min(moving, fixed - least), fixed) : (fixed, max(moving, fixed + least))
        return .zoomTo(
            Zoom(scale: TimelineScale(framesPerPoint: (high - low) / view.width), origin: low), stroke: stroke)
    }

    /// U9: resize over an edge, an open hand over the body, a closed hand during a drag.
    public func cursor(at x: Double, _ strip: OverviewGeometry, _ view: Viewport) -> TimelineCursor {
        switch state {
        case .scrolling, .resizing: return .closedHand
        case .idle, .pressed:
            switch strip.hit(x, view) {
            case .leadingEdge, .trailingEdge: return .resizeLeftRight
            case .body: return .openHand
            case .outside: return .arrow
            }
        }
    }
}
