/// A gain in dB, always in `Gain.range`.
public struct Gain: Hashable, Sendable, CustomStringConvertible {
    public let dB: Double

    /// Each edit path (the app, `dirigible`, MCP) refuses a gain outside it (track fader run).
    public static let range = -96.0...96.0
    /// The range in the texts of the CLI and MCP.
    public static let rangeText = "from \(Int(range.lowerBound)) to \(Int(range.upperBound))"

    /// Nil outside `range`, and for NaN and infinity.
    public init?(dB: Double) {
        guard Self.range.contains(dB) else { return nil }
        self.dB = dB
    }

    /// A stored or computed gain at the nearest end of `range`. Nil for NaN and infinity.
    public init?(clamping dB: Double) {
        guard dB.isFinite else { return nil }
        self.dB = min(max(dB, Self.range.lowerBound), Self.range.upperBound)
    }

    public static let zero = Gain(dB: 0)!
    /// The gain limit of decision 0008, in dB, in each direction: auto-level, the warning of the
    /// export report, the start rule of the gain drag of the lanes, the clamp of the inspector, and
    /// the top of the track fader (`FaderScale`).
    public static let levelLimit = 20.0
    /// The ride gain limit of Level Over Time, in dB, in each direction (decision 0060): the ride
    /// clamps to it, and a load refuses a ride gain past it.
    public static let rideLimit = 6.0
    public var description: String { "\(dB) dB" }
}
