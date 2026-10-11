import DirigibleCore

/// The travel of the track fader (F94): a position from 0 to 1 and a gain in dB, in three linear
/// parts. Position 0 to 0.25 is -60 to -20 dB, 0.25 to 0.75 is -20 to 0 dB, and 0.75 to 1 is 0 to
/// +20 dB (`Gain.levelLimit`), so 0 dB is at three quarters of the travel. A drag that starts at a
/// stored value outside the travel extends the end on that side to the start value, as the clip
/// gain drag does, so the first drag event does not jump.
public struct FaderScale: Sendable {
    public static let floor = -60.0
    public static let ceiling = Gain.levelLimit
    /// The drag values: a step of 0.5 dB, and 0 dB within 0.75 dB of 0.
    static let resolution = 0.5
    static let detent = 0.75

    private let points: [(position: Double, dB: Double)]

    public init(start: Double) {
        points = [(0, min(start, Self.floor)), (0.25, -20), (0.75, 0), (1, max(start, Self.ceiling))]
    }

    /// The thumb position of `dB`, from 0 to 1. A value outside the travel pins at its end.
    public func position(dB: Double) -> Double {
        guard dB > points[0].dB else { return 0 }
        guard let upper = points.firstIndex(where: { $0.dB >= dB }) else { return 1 }
        let (a, b) = (points[upper - 1], points[upper])
        return a.position + (dB - a.dB) / (b.dB - a.dB) * (b.position - a.position)
    }

    /// The gain at `position`, before the rounding.
    public func rawDB(position: Double) -> Double {
        let position = min(max(position, 0), 1)
        let upper = points.firstIndex { $0.position >= position } ?? points.count - 1
        guard upper > 0 else { return points[0].dB }
        let (a, b) = (points[upper - 1], points[upper])
        return a.dB + (position - a.position) / (b.position - a.position) * (b.dB - a.dB)
    }

    /// The gain of a drag at `position`: rounded to 0.5 dB, 0 dB in the detent, inside the travel.
    public func dB(position: Double) -> Double {
        let raw = rawDB(position: position)
        guard abs(raw) >= Self.detent else { return 0 }
        let rounded = (raw / Self.resolution).rounded() * Self.resolution
        return min(max(rounded, points[0].dB), points[points.count - 1].dB)
    }

    /// The gain after a key step of `delta` dB (Raise or Lower Track Volume). A step stops at the
    /// end of the travel; a stored value outside it does not move further out.
    public static func step(_ dB: Double, by delta: Double) -> Double {
        delta > 0 ? min(dB + delta, max(dB, ceiling)) : max(dB + delta, min(dB, floor))
    }
}
