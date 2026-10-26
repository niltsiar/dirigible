import DirigibleCore

/// One stage of a clip render (decision 0054). The case order is the chain order.
public enum Effect: Hashable, Sendable {
    case noise(NoiseReduction)

    /// The place of the kind in the chain. Two effects of one kind cannot be in one treatment.
    fileprivate var kind: Int {
        switch self {
        case .noise: 0
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
        let sorted = effects.sorted { $0.kind < $1.kind }
        guard !sorted.isEmpty, Set(sorted.map(\.kind)).count == sorted.count else { return nil }
        self.effects = sorted
    }

    /// The suffix of the stem of each new file: " NR" when the effects hold noise.
    var suffix: String { usesSoundIsolation ? " NR" : "" }

    /// True when the effects hold noise, so the chain loads AUSoundIsolation.
    var usesSoundIsolation: Bool { effects.contains { if case .noise = $0 { true } else { false } } }

    /// The noise amount, when the effects hold noise.
    var noise: NoiseReduction? {
        effects.lazy.compactMap { if case .noise(let amount) = $0 { amount } else { nil } }.first
    }

    /// False for a `.music` or `.effects` track when the effects hold noise, because the voice unit
    /// removes music and effects; else true. Nil, the default role of every track (decision 0060),
    /// is true. The one rule of the app filter and of the refusal of `renderClips`.
    public func accepts(_ role: Track.Role?) -> Bool {
        guard usesSoundIsolation else { return true }
        return role != .music && role != .effects
    }
}
