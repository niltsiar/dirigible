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

/// One stage of a clip render, in the stored form (decisions 0054, 0057). The case order is the
/// chain order.
public enum Effect: Hashable, Sendable {
    case noise(NoiseReduction)

    /// The kind of an effect. Two effects of one kind cannot be in one treatment. The raw value is
    /// the place of the kind in the chain.
    public enum Kind: Int, Sendable, CaseIterable {
        case noise
    }

    public var kind: Kind {
        switch self {
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
}
