import Foundation

/// A string ID of one kind of object. The tag makes a `TrackID` and a `ClipID` different types.
/// Callers can give their own IDs, because capture makes deterministic IDs (decision 0004).
public struct ID<Tag>: Hashable, Comparable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
    /// A new unique ID, for objects that the user makes.
    public init() { self.init(UUID().uuidString) }
    public init(stringLiteral value: String) { self.init(value) }

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    public var description: String { rawValue }
}

/// A count or a position in frames at the session sample rate. A device sample time or a
/// latency is at the device rate, so it is not `Frames`.
public struct Frames: Hashable, Comparable, Sendable, AdditiveArithmetic, ExpressibleByIntegerLiteral,
    CustomStringConvertible
{
    public var count: Int

    public init(_ count: Int) { self.count = count }
    public init(integerLiteral value: Int) { self.count = value }

    public static let zero = Frames(0)
    /// The largest position or length: 2^40 frames, about 260 days at 48 kHz. Sums of two
    /// values in `0...limit` cannot overflow.
    public static let limit = Frames(1 << 40)
    public static func + (a: Frames, b: Frames) -> Frames { Frames(a.count + b.count) }
    public static func - (a: Frames, b: Frames) -> Frames { Frames(a.count - b.count) }
    public static func < (a: Frames, b: Frames) -> Bool { a.count < b.count }
    public var description: String { String(count) }

    var isInRange: Bool { self >= .zero && self <= .limit }
}

/// A gain in dB. It is always finite.
public struct Gain: Hashable, Sendable, CustomStringConvertible {
    public let dB: Double

    public init?(dB: Double) {
        guard dB.isFinite else { return nil }
        self.dB = dB
    }

    public static let zero = Gain(dB: 0)!
    public var description: String { "\(dB) dB" }
}

public enum ChannelLayout: String, Sendable {
    case mono, stereo

    public init?(channelCount: Int) {
        switch channelCount {
        case 1: self = .mono
        case 2: self = .stereo
        default: return nil
        }
    }

    public var channelCount: Int { self == .mono ? 1 : 2 }
}
