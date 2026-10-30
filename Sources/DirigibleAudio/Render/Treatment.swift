import DirigibleCore

extension Treatment {
    /// The suffix of the stem of each new file: " NR" when the effects hold noise, " HR" when they
    /// hold hum and no noise, else " RP" (a repair).
    var suffix: String { usesSoundIsolation ? " NR" : hum != nil ? " HR" : " RP" }

    /// True when the effects hold noise, so the chain loads AUSoundIsolation.
    var usesSoundIsolation: Bool { noise != nil }

    /// The noise amount, when the effects hold noise.
    public var noise: NoiseReduction? {
        effects.lazy.compactMap { if case .noise(let amount) = $0 { amount } else { nil } }.first
    }

    /// The hum frequency, when the effects hold hum.
    public var hum: Hum? {
        effects.lazy.compactMap { if case .hum(let hertz) = $0 { hertz } else { nil } }.first
    }

    /// The de-clip, when the effects hold one.
    public var declip: Declip? {
        effects.lazy.compactMap { if case .declip(let value) = $0 { value } else { nil } }.first
    }

    /// The high-pass, when the effects hold one.
    public var rumble: Rumble? {
        effects.lazy.compactMap { if case .rumble(let value) = $0 { value } else { nil } }.first
    }

    /// The de-ess, when the effects hold one.
    public var deess: DeEss? { effects.lazy.compactMap { if case .deess(let value) = $0 { value } else { nil } }.first }

    /// False for a `.music` or `.effects` track when the effects hold noise, because the voice unit
    /// removes music and effects; else true. Nil, the default role of every track (decision 0060),
    /// is true. The one rule of the app filter and of the refusal of `renderClips` and
    /// `renderRequest`.
    public func accepts(_ role: Track.Role?) -> Bool {
        guard usesSoundIsolation else { return true }
        return role != .music && role != .effects
    }

    /// Throws `.trackRole` for the first clip of `clips` whose track has a role that `accepts`
    /// refuses. A clip that is not in `session` passes.
    func checkRoles(of clips: [ClipID], in session: Session) throws(ClipRenderError) {
        for clip in clips {
            let role = session.clip(clip).flatMap { session.track($0.track)?.role }
            if let role, !accepts(role) { throw .trackRole(clip: clip, role: role) }
        }
    }
}
