import Foundation

/// The width of the track header panel (decision 0023): 180 to 480 pt in whole points, so the
/// header edge is on a pixel edge at scale 1 and 2. An out-of-range width cannot exist.
public struct HeaderWidth: PaneWidth {
    public static let standard = HeaderWidth(340)
    /// The app preference: a `Double` of points. Never change its meaning or its type (0024 P11).
    public static let defaultsKey = "timeline.header.width"

    public let points: Double

    /// NaN gives the standard width.
    public init(_ points: Double) {
        self.points = points.isNaN ? Self.standard.points : min(480, max(180, points.rounded()))
    }
}
