import Foundation

/// The width of the leading index pane with its divider (decision 0023): 240 to 400 pt in whole
/// points. The window also limits it to its content width minus the lanes minimum.
public struct IndexWidth: PaneWidth {
    public static let standard = IndexWidth(240)
    /// The app preference: a `Double` of points. Never change its meaning or its type (0024 P11).
    public static let defaultsKey = "view.index.width"

    public let points: Double

    /// NaN gives the standard width.
    public init(_ points: Double) {
        self.points = points.isNaN ? Self.standard.points : min(400, max(240, points.rounded()))
    }
}
