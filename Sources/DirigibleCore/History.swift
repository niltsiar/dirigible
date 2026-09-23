import Foundation

/// Snapshot undo (decision 0002): each entry is a whole `Session` value.
///
/// Undo and redo keep the current `recording`. The `<recording>` element records a take on the
/// disk, not an edit, so an undo must not bring back a take that finalize already placed.
public struct History: Hashable, Sendable {
    public private(set) var session: Session
    private var undoStack: [Session] = []
    private var redoStack: [Session] = []

    public init(_ session: Session) {
        self.session = session
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Runs `body` on a copy of the session. A throw discards the copy. An edit that changes
    /// only `recording` records no entry, because undo could not change it back.
    @discardableResult
    public mutating func edit<Result>(_ body: (inout Session) throws -> Result) rethrows -> Result {
        var copy = session
        let result = try body(&copy)
        var withOldRecording = copy
        withOldRecording.recording = session.recording
        if withOldRecording != session {
            undoStack.append(session)
            redoStack.removeAll()
        }
        session = copy
        return result
    }

    /// Throws `.trackInRecording` and changes nothing if the entry has no track that the
    /// current recording arms.
    public mutating func undo() throws(SessionError) {
        guard let entry = undoStack.last else { return }
        let restored = try keepingRecording(entry)
        undoStack.removeLast()
        redoStack.append(session)
        session = restored
    }

    public mutating func redo() throws(SessionError) {
        guard let entry = redoStack.last else { return }
        let restored = try keepingRecording(entry)
        redoStack.removeLast()
        undoStack.append(session)
        session = restored
    }

    private func keepingRecording(_ entry: Session) throws(SessionError) -> Session {
        if let missing = session.recording?.armedTracks.first(where: { entry.track($0) == nil }) {
            throw .trackInRecording(missing)
        }
        var restored = entry
        restored.recording = session.recording
        return restored
    }
}
