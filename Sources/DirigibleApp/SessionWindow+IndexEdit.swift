import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleTimeline

/// The edits of the index list that act on several rows. Each writes the rows through the index form
/// of `TimelineState.selectRows`, which seeks nowhere.
extension SessionWindow {
    /// Command-A in the list: the rows that the kind filter and the search show. The anchor stays
    /// while it shows.
    func selectAllIndexRows() {
        guard let session = studio?.session else { return }
        let pane = leadingPane
        let shown = pane.sessionIndex(for: session).rows(kind: pane.kind, search: pane.search, keeping: pane.editedRow)
        guard let first = shown.first else { return beep() }
        let picks = Set(shown.map(\.id))
        let anchor = timeline.anchorRow.flatMap { picks.contains($0) ? $0 : nil } ?? first.id
        timeline.selectRows(picks, anchor: anchor, form: .indexSet)
    }

    /// Takes each selected row that the kind filter and the search hide off the selection. It writes
    /// only when a row goes, so a command that drops nothing pushes nothing.
    func dropHiddenIndexRows() {
        let selected = timeline.selectedRows
        guard !selected.isEmpty, let session = studio?.session else { return }
        let pane = leadingPane
        let kept = pane.sessionIndex(for: session)
            .shownPicks(of: selected, kind: pane.kind, search: pane.search, keeping: pane.editedRow)
        guard kept != selected else { return }
        let anchor =
            timeline.anchorRow.flatMap { kept.contains($0) ? $0 : nil } ?? SessionIndex.first(of: kept, in: session)
        timeline.selectRows(kept, anchor: anchor, form: .indexSet)
    }

    /// Delete in the list (Backspace, Edit > Delete): each selected row goes in one edit, so one Undo
    /// gives them all back. The row after the last removed row is selected, with no seek, and the
    /// window posts the count. A take or an import does nothing.
    func deleteIndexRows() {
        guard canEdit, let studio else { return }
        dropHiddenIndexRows()
        let picks = timeline.selectedRows
        guard !picks.isEmpty else { return }
        let pane = leadingPane
        let shown = pane.sessionIndex(for: studio.session)
            .rows(kind: pane.kind, search: pane.search, keeping: pane.editedRow)
        let next = shown.lastIndex { picks.contains($0.id) }
            .flatMap { shown[($0 + 1)...].first ?? shown.last { !picks.contains($0.id) } }?.id
        guard removeIndexRows(picks) else { return }
        timeline.selectRows(next.map { [$0] } ?? [], anchor: next, form: .indexSet)
        indexDeletePresses += 1
        indexDeleted = IndexDeletedShown(
            count: picks.count, revision: studio.sessionRevision, press: indexDeletePresses)
        pane.announce(L10n.indexPostDeleted.format(picks.count))
    }

    /// The edit of a list Delete: a clip row goes as the lane Delete removes a clip (no gap closes),
    /// a marker or chapter row as Delete Marker. True when the edit ran.
    @discardableResult func removeIndexRows(_ picks: Set<SessionIndex.Pick>) -> Bool {
        var (clips, markers): (Set<ClipID>, [MarkerID]) = ([], [])
        for case .clip(let id) in picks { clips.insert(id) }
        for case .marker(let id) in picks { markers.append(id) }
        let removed: Void? = edit(ripple: false) { session throws(SessionError) in
            if let set = ClipSet(clips), let result = try Selection.clips(set).deleted(session) { session = result }
            for id in markers { try session.removeMarker(id) }
        }
        return removed != nil
    }

    /// The row action Delete: the rows that are selected when the row is one of them, else the row alone.
    func deleteIndexRow(_ pick: SessionIndex.Pick) {
        guard canEdit else { return }
        if !timeline.selectedRows.contains(pick) { timeline.selectRows([pick], anchor: pick, form: .indexSet) }
        deleteIndexRows()
    }
}
