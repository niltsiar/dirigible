/// The range of the waveform: the dB that a lane height shows, from 0 dBFS at the lane top down.
/// The lanes, the waveform, and the gain drags scale with it, so the gain line stays on the top of
/// its signal and under the pointer.
public enum WaveformRange: Int, CaseIterable, Sendable {
    case db24 = 24
    case db36 = 36
    case db48 = 48
    case db60 = 60
    case db72 = 72
    case db84 = 84
    case db96 = 96

    /// The range that a new window and a stored value that is not a range open at.
    public static let standard = WaveformRange.db60

    public var dB: Double { Double(rawValue) }

    /// The next range that shows more dB per lane height, so a quiet signal draws taller. Nil at 96 dB.
    public var zoomedIn: WaveformRange? { Self.allCases.first { $0.rawValue > rawValue } }

    /// The next range that shows fewer dB per lane height. Nil at 24 dB.
    public var zoomedOut: WaveformRange? { Self.allCases.last { $0.rawValue < rawValue } }

    /// The range of a stored value: `standard` for a value that is not the dB of a range.
    public init(stored: Any?) {
        self = (stored as? Int).flatMap(Self.init(rawValue:)) ?? .standard
    }

    /// The fraction of the lane height of a 0 dBFS signal at `dB`: 1 at 0 dB, 0 at -R dB and
    /// under. `LaneRenderer` draws with it, so the line and the waveform agree.
    public func fraction(dB: Double) -> Double { min(max((dB + self.dB) / self.dB, 0), 1) }

    /// The dB of a drag of `points` over a lane of `laneHeight` points. The product comes first,
    /// so a whole number of points per dB gives an exact dB.
    public func decibels(points: Double, laneHeight: Double) -> Double { points * dB / laneHeight }
}
