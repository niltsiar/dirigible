/// The vari-speed of a play at the shuttle rate 1x, with the pitch kept (decision 0048). The raw
/// value is in hundredths. Not a shuttle rate: 0.5x, 2x, and 4x keep tape pitch (0016).
public enum Speed: Int, CaseIterable, Hashable, Sendable {
    case x075 = 75
    case one = 100
    case x125 = 125
    case x150 = 150
    case x175 = 175
    case x200 = 200

    public var factor: Double { Double(rawValue) / 100 }

    /// The next step up; the last step stays.
    public var faster: Speed { Self.allCases.first { $0.rawValue > rawValue } ?? self }

    /// The next step down; the first step stays.
    public var slower: Speed { Self.allCases.last { $0.rawValue < rawValue } ?? self }
}
