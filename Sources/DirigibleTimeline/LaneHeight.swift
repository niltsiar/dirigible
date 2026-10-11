/// The height of the lanes of a window (decision 0025): automatic, the fit of 0017, or a fixed
/// step. Window state, not saved. Whole points, so the 0022 surfaces never get a fractional
/// capacity.
public enum LaneHeight: Equatable, Sendable {
    case automatic
    case fixed(Double)

    /// Q9: 200 pt keeps the 0022 surface memory at about 93 MB.
    public static let steps: [Double] = [40, 50, 60, 80, 100, 120, 160, 200]

    /// Automatic: the free height over the tracks, 40 to 200 pt, rounded down to whole points.
    public func points(free: Double, tracks: Int) -> Double {
        switch self {
        case .automatic: min(200, max(40, (free / Double(max(1, tracks))).rounded(.down)))
        case .fixed(let points): points
        }
    }

    /// The next step above the height in view `shown`; at 200 pt it stays.
    public func taller(than shown: Double) -> LaneHeight {
        .fixed(Self.steps.first { $0 > shown } ?? Self.steps.last!)
    }

    /// The next step below the height in view `shown`; at 40 pt it stays.
    public func shorter(than shown: Double) -> LaneHeight {
        .fixed(Self.steps.last { $0 < shown } ?? Self.steps.first!)
    }
}
