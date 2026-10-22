import DirigibleCore
import Foundation

/// The take sync change of one revision of the session (decision 0061).
public struct TakeSyncChange: Equatable, Sendable {
    /// The `sessionRevision` that the change was made at.
    public let revision: Int
    /// The agent of an edit, of a redo of an agent entry, or of an import. Nil for a user edit, an
    /// undo, a take outcome, and a prune.
    public let agent: AgentName?
    /// The transitions from the revision before (`TakeSync.change(from:to:)`). Empty when the
    /// anchors of either revision do not read.
    public let changes: [TakeSync.Change]
}

/// The take anchors of the studio, and the take map and the change of the last revision.
struct TakeSyncState {
    /// The take anchors of the package, or the read fault: from the open and each take outcome.
    var anchors: Result<[Int: Recording], FinalizeError>
    private(set) var map: Result<TakeMap, FinalizeError>
    private(set) var change = TakeSyncChange(revision: 0, agent: nil, changes: [])
    /// The maps made, for the tests.
    private(set) var made = 1

    init(_ session: Session, anchors: Result<[Int: Recording], FinalizeError>) {
        self.anchors = anchors
        map = TakeMap.of(session, anchors: anchors)
    }

    /// Makes the map of `session` and its change from the map before, once for each revision.
    mutating func update(_ session: Session, revision: Int, agent: AgentName?) {
        guard revision != change.revision else { return }
        let old = map
        map = TakeMap.of(session, anchors: anchors)
        made += 1
        var changes: [TakeSync.Change] = []
        if case .success(let before) = old, case .success(let after) = map {
            changes = TakeSync.change(from: before.sync, to: after.sync)
        }
        change = TakeSyncChange(revision: revision, agent: agent, changes: changes)
    }
}

extension Studio {
    /// The take map of the session (decision 0061), or the anchor read fault. It is made once for
    /// each revision, with the anchors of the open and of the last take outcome.
    public var takeMap: Result<TakeMap, FinalizeError> { takeSyncState.map }

    /// The anchor read fault that keeps the take map from the session, or nil.
    public var takeSyncFault: FinalizeError? {
        if case .failure(let error) = takeMap { error } else { nil }
    }

    /// The take sync change of the last revision of an edit, an undo, a redo, a take outcome, an
    /// import, or a prune. A level or a duck changes only gains and envelopes, so it makes none.
    public var takeSyncChange: TakeSyncChange { takeSyncState.change }
}
