import DirigibleCore

/// One effect of a render request, in the form that the user asks for (decision 0057). The
/// measure phase of a render turns it into the stored `Effect`.
public enum EffectRequest: Hashable, Sendable {
    /// An effect that needs no measure: the stored form as it is.
    case effect(Effect)

    public var kind: Effect.Kind {
        switch self {
        case .effect(let effect): effect.kind
        }
    }
}

/// What a render request asks for: one or more effects, each kind once, in chain order. A stored
/// level enters a render plan as `ClipRenderRequest(stored)`, so the merge, the removal, and the
/// compare of the levels are operations of this type only (decision 0057).
public struct ClipRenderRequest: Hashable, Sendable {
    public let effects: [EffectRequest]
    /// The kinds that the render takes out of the stored levels of each clip. It holds no kind of
    /// `effects`.
    public let removed: Set<Effect.Kind>

    /// The effects of `treatment`, and each kind of `removing` that `treatment` does not hold as a
    /// removal.
    public init(_ treatment: Treatment, removing: Set<Effect.Kind> = []) {
        effects = treatment.effects.map(EffectRequest.effect)
        removed = removing.subtracting(treatment.effects.map(\.kind))
    }

    /// No check: each caller gives effects of distinct kinds in chain order.
    private init(sorted effects: [EffectRequest]) { (self.effects, removed) = (effects, []) }

    /// The kinds of the effects.
    var kinds: Set<Effect.Kind> { Set(effects.map(\.kind)) }

    /// The kinds that a render of this request sets or removes.
    var touched: Set<Effect.Kind> { kinds.union(removed) }

    /// This request with each effect of `other` in place of the effect of its kind, or added, and
    /// with no effect of a kind that `other` removes.
    func replacing(with other: ClipRenderRequest) -> ClipRenderRequest {
        let kept = effects.filter { !other.touched.contains($0.kind) }
        return ClipRenderRequest(sorted: (kept + other.effects).sorted { $0.kind.rawValue < $1.kind.rawValue })
    }

    /// This request with no effect of `kinds`, or nil when no effect is left: the level goes.
    func removing(_ kinds: Set<Effect.Kind>) -> ClipRenderRequest? {
        let kept = effects.filter { !kinds.contains($0.kind) }
        return kept.isEmpty ? nil : ClipRenderRequest(sorted: kept)
    }

    /// True when each effect equals the stored effect of its kind in `stored`, and `stored` holds
    /// no removed kind. Only an effect that reads no clip gain can be unchanged: a later kind that
    /// reads it (the ride, the match) is never unchanged.
    func isUnchanged(from stored: Treatment) -> Bool {
        !stored.effects.contains { removed.contains($0.kind) }
            && effects.allSatisfy { request in
                switch request {
                case .effect(let effect): stored.effects.contains(effect)
                }
            }
    }

    /// The stored form, as the measure phase gives it.
    var treatment: Treatment {
        Treatment(
            effects.map { request in
                switch request {
                case .effect(let effect): effect
                }
            })!
    }
}
