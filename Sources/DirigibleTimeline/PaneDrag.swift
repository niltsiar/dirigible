import Foundation

/// A clamped pane width in whole points with a standard value: the track header panel and the
/// inspector (decision 0023). An out-of-range width cannot exist.
public protocol PaneWidth: Equatable, Sendable {
    static var standard: Self { get }
    var points: Double { get }
    /// Clamps and rounds; NaN gives the standard width.
    init(_ points: Double)
}

/// An event of a pane handle. The pointer x grows toward a wider pane.
public enum PaneDragEvent: Equatable, Sendable {
    case down(x: Double, clicks: Int)
    case drag(x: Double)
    case up
    case escape
}

/// The width after an event, and whether the preference saves it.
public struct PaneDragStep<Width: PaneWidth>: Equatable, Sendable {
    public let width: Width
    public let save: Bool
}

/// The drag of a pane handle (the ui-shell design, "Header drag: states x events"). A drag is
/// live and saves nothing; the up saves when the width differs from the start; Esc gives the start
/// width; a double-click gives the standard width and saves it.
public struct PaneDrag<Width: PaneWidth>: Sendable {
    /// The width at the mouse-down, and the pointer x minus that width.
    private var press: (start: Width, grab: Double)?

    public init() {}

    public var isActive: Bool { press != nil }
    /// The width at the mouse-down of the drag; nil when idle.
    public var start: Width? { press?.start }
    var grab: Double? { press?.grab }

    /// The new width, or nil when the event is not taken (an Esc, a drag, or an up while idle).
    public mutating func handle(_ event: PaneDragEvent, width: Width) -> PaneDragStep<Width>? {
        switch (event, press) {
        case (.down(_, let clicks), _) where clicks >= 2:
            press = nil
            return PaneDragStep(width: .standard, save: true)
        case (.down(let x, _), _):
            press = (width, x - width.points)
            return PaneDragStep(width: width, save: false)
        case (.drag(let x), let press?):
            return PaneDragStep(width: Width(x - press.grab), save: false)
        case (.up, let press?):
            self.press = nil
            return PaneDragStep(width: width, save: width != press.start)
        case (.escape, let press?):
            self.press = nil
            return PaneDragStep(width: press.start, save: false)
        case (.drag, nil), (.up, nil), (.escape, nil):
            return nil
        }
    }
}
