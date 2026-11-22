import DirigibleCore

/// The undo and redo state that the Edit menu reads.
extension Studio {
    public var canUndo: Bool { history.canUndo }
    public var canRedo: Bool { history.canRedo }
    /// The agent of the change that Undo reverts, or nil for a user change (decision 0046).
    public var undoAgent: AgentName? { history.undoAgent }
    /// The agent of the change that Redo makes again, or nil for a user change.
    public var redoAgent: AgentName? { history.redoAgent }
    /// The name of the change that Undo reverts, for its menu title, or nil for a plain edit.
    public var undoName: History.Name? { history.undoName }
    /// The name of the change that Redo makes again, or nil.
    public var redoName: History.Name? { history.redoName }
}
