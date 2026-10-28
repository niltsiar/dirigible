import DirigibleCore

extension Treatment {
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
