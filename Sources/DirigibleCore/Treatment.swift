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

/// One stage of a clip render, in the stored form (decisions 0054, 0057). The case order is the
/// chain order.
public enum Effect: Hashable, Sendable {
    case hum(Hum)
    case noise(NoiseReduction)

    /// The kind of an effect. Two effects of one kind cannot be in one treatment. The raw value is
    /// the place of the kind in the chain.
    public enum Kind: Int, Sendable, CaseIterable {
        case hum
        case noise
    }

    public var kind: Kind {
        switch self {
        case .hum: .hum
        case .noise: .noise
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

    /// The `session.xml` version of an origin with this treatment (decision 0057 D9): 13 with hum,
    /// else 12.
    var fileVersion: Int { effects.contains { $0.kind == .hum } ? 13 : 12 }
}
