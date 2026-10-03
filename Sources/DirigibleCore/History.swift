import Foundation

/// Snapshot undo (decision 0002): each entry is a whole `Session` value.
///
/// Undo and redo keep the current `recording`. The `<recording>` element records a take on the
/// disk, not an edit, so an undo must not bring back a take that finalize already placed.
public struct History: Hashable, Sendable {
    public private(set) var session: Session
    private var undoStack: [Session] = []
    private var redoStack: [Session] = []
    /// One more for each recorded edit, undo, and redo, so a reader can tell that the session
    /// changed since a moment (the export report banner).
    public private(set) var revision = 0

    public init(_ session: Session) {
        self.session = session
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Runs `body` on a copy of the session. A throw discards the copy. An edit that changes
    /// only `recording` records no entry, because undo could not change it back.
    @discardableResult
    public mutating func edit<Result, Failure: Error>(
        _ body: (inout Session) throws(Failure) -> Result
    ) throws(Failure) -> Result {
        var copy = session
        let result = try body(&copy)
        var withOldRecording = copy
        withOldRecording.recording = session.recording
        if withOldRecording != session {
            undoStack.append(session)
            redoStack.removeAll()
            revision += 1
        }
        session = copy
        return result
    }

    /// Throws `.trackInRecording` and changes nothing if the entry removes a track that the
    /// current recording arms, or changes its route or layout (decision 0012).
    public mutating func undo() throws(SessionError) {
        guard let entry = undoStack.last else { return }
        let restored = try keepingRecording(entry)
        undoStack.removeLast()
        redoStack.append(session)
        session = restored
        revision += 1
    }

    public mutating func redo() throws(SessionError) {
        guard let entry = redoStack.last else { return }
        let restored = try keepingRecording(entry)
        redoStack.removeLast()
        undoStack.append(session)
        session = restored
        revision += 1
    }

    private func keepingRecording(_ entry: Session) throws(SessionError) -> Session {
        let changed = session.recording?.armedTracks.first { id in
            let old = session.track(id)
            let new = entry.track(id)
            return new == nil || new?.route != old?.route || new?.layout != old?.layout
        }
        if let changed { throw .trackInRecording(changed) }
        var restored = entry
        restored.recording = session.recording
        return restored
    }
}
