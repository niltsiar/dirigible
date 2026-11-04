import DirigibleCore

extension Studio {
    /// The one edit core: runs `body` on a copy of the session and records one undo entry if it
    /// changed. A change schedules one autosave of the new session; `edit` does not wait for it.
    /// A busy studio throws `refused(.busy)`; a throw of `body` changes nothing. `agent` names the
    /// agent of an MCP edit in its undo entry (decision 0046). `body` reads only its copy.
    public func edit<Result, Failure: Error>(
        agent: AgentName?, refused: (StudioError) -> Failure, _ body: (inout Session) throws(Failure) -> Result
    ) throws(Failure) -> Result {
        do { try checkIdle() } catch { throw refused(error) }
        return try recordEdit(agent: agent, body)
    }
}
