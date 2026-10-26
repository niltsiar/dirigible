import DirigibleCore

extension Studio {
    /// The ripple rule of decision 0037 for a session value of this studio. It reads the given
    /// session and the segment sets, not the stored session, so an edit body can ask it of its copy.
    public func canRipple(_ session: Session) -> Bool {
        !rippleBlocked(segments: segmentsWithAudio.filter { !notAudioSegments.contains($0) }, session: session)
    }

    /// The edit core with a `SessionError` body. A caller declares a ripple with `ripple`: under a
    /// pending or split take, it throws `.rippleBlocked` (decision 0037), after the busy check.
    public func edit<Result>(
        ripple: Bool, agent: AgentName? = nil, _ body: (inout Session) throws(SessionError) -> Result
    ) throws(StudioError) -> Result {
        try edit(
            agent: agent, refused: { $0 },
            { s throws(StudioError) in
                if ripple, !canRipple(s) { throw .rippleBlocked }
                do throws(SessionError) { return try body(&s) } catch { throw .session(error) }
            })
    }
}
