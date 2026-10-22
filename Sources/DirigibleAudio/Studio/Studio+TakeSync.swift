import DirigibleCore
import Foundation

/// The take sync change of one revision of the session (decision 0061).
public struct TakeSyncChange: Equatable, Sendable {
    /// The `sessionRevision` that the change was made at.
    public let revision: Int
    /// The agent of an edit, of a redo of an agent entry, or of an import. Nil for a user edit, an
    /// undo, a take outcome, and a prune.
    public let agent: AgentName?
    /// The transitions from the revision before (`TakeSync.change(from:to:)`). A take whose
    /// anchor does not read is in neither map, so it gives no entry.
    public let changes: [TakeSync.Change]
}

/// The take anchors of the studio, and the take map and the change of the last revision.
struct TakeSyncState {
    /// The take anchors of the package, or the read fault: from the open and each take outcome.
    private(set) var anchors: TakeAnchorRead
    private(set) var map: TakeMapRead
    private(set) var change = TakeSyncChange(revision: 0, agent: nil, changes: [])

    init(_ session: Session, anchors: TakeAnchorRead) {
        self.anchors = anchors
        map = TakeMap.of(session, anchors: anchors)
    }

    /// Stores the anchors of a take outcome and makes the map of `session` again, so the map always
    /// comes from the stored anchors. It records no change and no revision.
    mutating func store(_ anchors: TakeAnchorRead, session: Session) {
        self.anchors = anchors
        map = TakeMap.of(session, anchors: anchors)
    }

    /// Makes the map of `session` and its change from the map before, once for each revision. A
    /// take outcome or a placement passes `transitions: false`: it is never a transition.
    mutating func update(_ session: Session, revision: Int, agent: AgentName?, transitions: Bool = true) {
        guard revision != change.revision else { return }
        let old = map
        map = TakeMap.of(session, anchors: anchors)
        let changes = transitions ? TakeSync.change(from: old.map.sync, to: map.map.sync) : []
        change = TakeSyncChange(revision: revision, agent: agent, changes: changes)
    }
}

extension Studio {
    /// The take map of the session (decision 0061), and the anchor read faults. It is made once
    /// for each revision, with the anchors of the open and of the last take outcome.
    public var takeMap: TakeMapRead { takeSyncState.map }

    /// The first anchor read fault, in take order, or nil.
    public var takeSyncFault: FinalizeError? { takeMap.faults.first?.error }

    /// The take sync change of the last revision of an edit, an undo, a redo, a take outcome, an
    /// import, or a prune. A level or a duck changes only gains and envelopes, so it makes none.
    public var takeSyncChange: TakeSyncChange { takeSyncState.change }
}
