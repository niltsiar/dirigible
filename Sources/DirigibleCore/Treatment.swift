import Foundation

/// Whole decibels of noise reduction, 1 to 30 (decision 0054): the one parse of the amount for the
/// app, the CLI, and MCP.
public struct NoiseReduction: Hashable, Sendable {
    public static let range = 1...30
    /// The amount of Tools > Reduce Noise and the default of the command and the tool.
    public static let standard = NoiseReduction(decibels: 12)!
    public let decibels: Int

    /// Nil outside `range`.
    public init?(decibels: Int) {
        guard Self.range.contains(decibels) else { return nil }
        self.decibels = decibels
    }
}

/// The mains frequency of a hum removal (decision 0054): the band-stop takes this frequency and
/// its next three harmonics. `init?(rawValue:)` is the one parse of the app, the CLI, MCP, and the
/// session reader.
public enum Hum: Int, Hashable, Sendable, CaseIterable {
    case hz50 = 50
    case hz60 = 60
}

/// Reduce Rumble (decision 0064 D3): a 12 dB per octave Butterworth high-pass at `hertz`.
public struct Rumble: Hashable, Sendable {
    public static let range = 20...300
    public static let standard = Rumble(hertz: 80)!
    public let hertz: Int

    /// Nil outside `range`.
    public init?(hertz: Int) {
        guard Self.range.contains(hertz) else { return nil }
        self.hertz = hertz
    }
}

/// Repair Clipped Peaks (decision 0064 D4): a sample at or over `percent` of the channel peak of
/// the run is a clip candidate.
public struct Declip: Hashable, Sendable {
    public static let range = 90...100
    public static let standard = Declip(percent: 99)!
    public let percent: Int

    /// Nil outside `range`.
    public init?(percent: Int) {
        guard Self.range.contains(percent) else { return nil }
        self.percent = percent
    }
}

/// Soften "S" Sounds (decision 0064 D5): a split-band de-esser with its high band and its detector
/// at `hertz`, and a largest cut of `decibels`.
public struct DeEss: Hashable, Sendable {
    public static let hertzRange = 2_000...16_000
    public static let decibelRange = 1...40
    public static let standard = DeEss(hertz: 6_000, decibels: 10)!
    public let hertz: Int
    public let decibels: Int

    /// Nil when a value is outside its range.
    public init?(hertz: Int, decibels: Int) {
        guard Self.hertzRange.contains(hertz), Self.decibelRange.contains(decibels) else { return nil }
        (self.hertz, self.decibels) = (hertz, decibels)
    }
}

/// One stage of a clip render, in the stored form (decisions 0054, 0057, 0064). The case order is
/// the chain order.
public enum Effect: Hashable, Sendable {
    case declip(Declip)
    case rumble(Rumble)
    case hum(Hum)
    case noise(NoiseReduction)
    case deess(DeEss)

    /// The kind of an effect. Two effects of one kind cannot be in one treatment. The raw value is
    /// the place of the kind in the chain.
    public enum Kind: Int, Sendable, CaseIterable {
        case declip
        case rumble
        case hum
        case noise
        case deess
    }

    public var kind: Kind {
        switch self {
        case .declip: .declip
        case .rumble: .rumble
        case .hum: .hum
        case .noise: .noise
        case .deess: .deess
        }
    }
}

/// What a clip render does: one or more effects, each kind once, in chain order. No treatment is
/// empty.
public struct Treatment: Hashable, Sendable {
    public let effects: [Effect]

    public init(_ effect: Effect) { effects = [effect] }

    /// Nil when `effects` is empty or holds one kind twice; else the effects in chain order.
    public init?(_ effects: [Effect]) {
        let sorted = effects.sorted { $0.kind.rawValue < $1.kind.rawValue }
        guard !sorted.isEmpty, Set(sorted.map(\.kind)).count == sorted.count else { return nil }
        self.effects = sorted
    }

    /// The `session.xml` version of an origin with this treatment (decisions 0057 D9, 0064 D7): 14
    /// with declip, rumble, or deess, else 13 with hum, else 12.
    var fileVersion: Int {
        let kinds = Set(effects.map(\.kind))
        return !kinds.isDisjoint(with: [.declip, .rumble, .deess]) ? 14 : kinds.contains(.hum) ? 13 : 12
    }
}
