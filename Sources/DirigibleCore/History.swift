import Foundation

/// Snapshot undo (decision 0002): each entry is a whole `Session` value.
///
/// Undo and redo keep the current `recording` through `Session.reverted(to:)`, as a revert to a
/// backup does (decision 0043). The `<recording>` element records a take on the disk, not an
/// edit, so an undo must not bring back a take that finalize already placed.
public struct History: Hashable, Sendable {
    /// The session on the other side of one recorded change, and the agent that made the change
    /// (decision 0046), or nil for the user.
    private struct Entry: Hashable, Sendable {
        let session: Session
        let agent: AgentName?
    }

    public private(set) var session: Session
    private var undoStack: [Entry] = []
    private var redoStack: [Entry] = []
    /// One more for each recorded edit, undo, and redo, so a reader can tell that the session
    /// changed since a moment (the export report banner).
    public private(set) var revision = 0

    public init(_ session: Session) {
        self.session = session
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    /// The agent of the change that `undo` reverts, or nil for a user change or no entry.
    public var undoAgent: AgentName? { undoStack.last?.agent }
    /// The agent of the change that `redo` makes again, or nil for a user change or no entry.
    public var redoAgent: AgentName? { redoStack.last?.agent }

    /// The undo and the redo entries: their clips keep their files (decision 0047 D3).
    public var entries: [Session] { (undoStack + redoStack).map(\.session) }

    /// Removes the pool entries `ids` from the session and from each undo and redo entry, with no
    /// new entry, so no undo brings back a pool entry of a file in the Trash (decision 0047 D3).
    /// The revision goes up by one. Throws `.fileInUse` and changes nothing when a clip of the
    /// session or of an entry uses an ID.
    public mutating func removeUnusedFiles(_ ids: Set<FileID>) throws(SessionError) {
        func removed(_ value: Session) throws(SessionError) -> Session {
            var copy = value
            for id in ids where copy.files[id] != nil { try copy.removeFile(id) }
            return copy
        }
        func removed(_ entry: Entry) throws(SessionError) -> Entry {
            Entry(session: try removed(entry.session), agent: entry.agent)
        }
        let (current, undo, redo) = (try removed(session), try undoStack.map(removed), try redoStack.map(removed))
        (session, undoStack, redoStack) = (current, undo, redo)
        revision += 1
    }

    /// Runs `body` on a copy of the session. A throw discards the copy. An edit that changes
    /// only `recording` records no entry, because undo could not change it back. `agent` names the
    /// agent of an MCP edit (decision 0046).
    @discardableResult
    public mutating func edit<Result, Failure: Error>(
        agent: AgentName? = nil, _ body: (inout Session) throws(Failure) -> Result
    ) throws(Failure) -> Result {
        var copy = session
        let result = try body(&copy)
        var withOldRecording = copy
        withOldRecording.recording = session.recording
        if withOldRecording != session {
            undoStack.append(Entry(session: session, agent: agent))
            redoStack.removeAll()
            revision += 1
        }
        session = copy
        return result
    }

    /// Runs `body` as a part of the last recorded edit, with no new entry: the reset of a fader
    /// double-click joins the edit of its first click. When the result equals the state before
    /// that edit, its entry goes. With no entry, it is `edit`. The entry keeps its agent.
    public mutating func amend<Failure: Error>(_ body: (inout Session) throws(Failure) -> Void) throws(Failure) {
        guard let before = undoStack.last?.session else { return try edit(body) }
        var copy = session
        try body(&copy)
        // As in `edit`, a change of only the recording is no change of the entry.
        var withCurrentRecording = copy
        withCurrentRecording.recording = session.recording
        guard withCurrentRecording != session else {
            session = copy
            return
        }
        var withOldRecording = copy
        withOldRecording.recording = before.recording
        if withOldRecording == before { undoStack.removeLast() }
        redoStack.removeAll()
        session = copy
        revision += 1
    }

    /// Throws `.trackInRecording` and changes nothing if the entry removes a track that the
    /// current recording arms, or changes its route or layout (decision 0012).
    public mutating func undo() throws(SessionError) {
        guard let entry = undoStack.last else { return }
        let restored = try session.reverted(to: entry.session)
        undoStack.removeLast()
        redoStack.append(Entry(session: session, agent: entry.agent))
        session = restored
        revision += 1
    }

    public mutating func redo() throws(SessionError) {
        guard let entry = redoStack.last else { return }
        let restored = try session.reverted(to: entry.session)
        redoStack.removeLast()
        undoStack.append(Entry(session: session, agent: entry.agent))
        session = restored
        revision += 1
    }
}

extension Session {
    /// `entry` with the `recording` of this session. Undo, redo, and a revert to a backup use it.
    /// Throws `.trackInRecording` if `entry` removes a track that the current recording arms, or
    /// changes its route or layout (decision 0012).
    public func reverted(to entry: Session) throws(SessionError) -> Session {
        let changed = recording?.armedTracks.first { id in
            let old = track(id)
            let new = entry.track(id)
            return new == nil || new?.route != old?.route || new?.layout != old?.layout
        }
        if let changed { throw .trackInRecording(changed) }
        var restored = entry
        restored.recording = recording
        return restored
    }
}
