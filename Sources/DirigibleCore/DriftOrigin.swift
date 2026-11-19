/// The source frames for each file frame of a drift-corrected file (decision 0077, D1). The value is
/// always finite and less than 1000 ppm from 1.
public struct DriftRatio: Hashable, Sendable {
    public let value: Double

    /// The largest rate error of a clock that the fit and the drift link accept.
    public static let limit = 1000e-6

    /// Nil for a value that is not finite, or is not between `1 - limit` and `1 + limit`.
    public init?(_ value: Double) {
        guard value > 1 - Self.limit, value < 1 + Self.limit else { return nil }
        self.value = value
    }
}
