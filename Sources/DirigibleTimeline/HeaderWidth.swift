import Foundation

/// The width of the track header panel (decision 0023): 180 to 480 pt in whole points, so the
/// header edge is on a pixel edge at scale 1 and 2. An out-of-range width cannot exist.
public struct HeaderWidth: Equatable, Sendable {
    public static let standard = HeaderWidth(340)
    /// The app preference: a `Double` of points. Never change its meaning or its type (0024 P11).
    public static let defaultsKey = "timeline.header.width"

    public let points: Double

    /// NaN gives the standard width.
    public init(_ points: Double) {
        self.points = points.isNaN ? Self.standard.points : min(480, max(180, points.rounded()))
    }

    /// A stored preference: a number of points, else the standard width (a missing key, a text).
    public init(stored: Any?) {
        self = (stored as? Double).map(HeaderWidth.init) ?? .standard
    }
}

/// An event of the header handle: the pointer x is in the coordinates of the header ruler.
public enum HeaderDragEvent: Equatable, Sendable {
    case down(x: Double, clicks: Int)
    case drag(x: Double)
    case up
    case escape
}

/// The width after an event, and whether the preference saves it.
public struct HeaderDragStep: Equatable, Sendable {
    public let width: HeaderWidth
    public let save: Bool
}

/// The drag of the header handle (the ui-shell design, "Header drag: states x events"). A drag is
/// live and saves nothing; the up saves when the width differs from the start; Esc gives the start
/// width; a double-click gives the standard width and saves it.
public struct HeaderDrag: Sendable {
    /// The width at the mouse-down, and the pointer x minus that width.
    private var press: (start: HeaderWidth, grab: Double)?

    public init() {}

    public var isActive: Bool { press != nil }
    /// The width at the mouse-down of the drag; nil when idle.
    public var start: HeaderWidth? { press?.start }
    var grab: Double? { press?.grab }

    /// The new width, or nil when the event is not taken (an Esc, a drag, or an up while idle).
    public mutating func handle(_ event: HeaderDragEvent, width: HeaderWidth) -> HeaderDragStep? {
        switch (event, press) {
        case (.down(_, let clicks), _) where clicks >= 2:
            press = nil
            return HeaderDragStep(width: .standard, save: true)
        case (.down(let x, _), _):
            press = (width, x - width.points)
            return HeaderDragStep(width: width, save: false)
        case (.drag(let x), let press?):
            return HeaderDragStep(width: HeaderWidth(x - press.grab), save: false)
        case (.up, let press?):
            self.press = nil
            return HeaderDragStep(width: width, save: width != press.start)
        case (.escape, let press?):
            self.press = nil
            return HeaderDragStep(width: press.start, save: false)
        case (.drag, nil), (.up, nil), (.escape, nil):
            return nil
        }
    }
}
