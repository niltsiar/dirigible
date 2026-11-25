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
        let index = pane.sessionIndex(for: session)
        let kept = index.shownPicks(of: selected, kind: pane.kind, search: pane.search, keeping: pane.editedRow)
        guard kept != selected else { return }
        // The rows are in timeline order, so the first kept row is the first kept pick.
        let anchor =
            timeline.anchorRow.flatMap { kept.contains($0) ? $0 : nil } ?? index.rows.first { kept.contains($0.id) }?.id
        timeline.selectRows(kept, anchor: anchor, form: .indexSet)
    }

    /// Delete in the list (Backspace, Edit > Delete): each selected row goes in one edit, so one Undo
    /// gives them all back. The row after the last removed row is selected, with no seek, and the
    /// window posts the count, with no banner. A take or an import does nothing.
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
        let select = { [self] in timeline.selectRows(next.map { [$0] } ?? [], anchor: next, form: .indexSet) }
        if let source = leadingPane.table?.dataSource as? IndexTableSource { source.fromList(select) } else { select() }
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

    /// Add Marker or Add Chapter from the list: the command runs as in the lanes, then the name field
    /// of the new row opens. A take adds its take marker and opens no field (`canEdit`), and a refused
    /// add leaves the markers as they are.
    func addIndexMarker(_ kind: Marker.Kind) {
        guard let studio else { return }
        finishRowEdit(save: true)
        let before = Set(studio.session.markers.keys)
        run(kind == .chapter ? .addChapter : .addMarker)
        guard let added = studio.session.markers.keys.first(where: { !before.contains($0) }) else { return }
        beginRowEdit(added)
    }

    /// The frame of a typed time, or nil: the text of `takeFrame` with no minus, and a frame that
    /// the timeline holds (0 to `Frames.limit`).
    static func startFrame(_ text: String, rate: Int) -> Frames? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("-"), let frame = takeFrame(trimmed, rate: rate),
            (0...Frames.limit.count).contains(frame)
        else { return nil }
        return Frames(frame)
    }

    /// True when `open` holds a value that its field can save: a name that `Marker.set(.name, text:)`
    /// takes, or a time that `startFrame` parses.
    func accepts(_ open: LeadingPaneState.RowEdit, in session: Session) -> Bool {
        switch open.field {
        case .name:
            var probe = session.markers[open.marker]
            return probe?.set(.name, text: open.text) ?? true
        case .start:
            return open.text == open.shown || Self.startFrame(open.text, rate: session.sampleRate) != nil
        }
    }

    /// Saves the value of a closed field in one edit. A text that equals the text first shown, a value
    /// that the marker already has, or a text that the field refuses writes nothing.
    func saveRowEdit(_ open: LeadingPaneState.RowEdit) {
        guard let studio = idleStudio, let stored = studio.session.markers[open.marker] else { return }
        var changed = stored
        switch open.field {
        case .name:
            guard changed.set(.name, text: open.text) else { return }
        case .start:
            guard open.text != open.shown, let frame = Self.startFrame(open.text, rate: studio.session.sampleRate)
            else { return }
            changed.position = frame
        }
        guard changed != stored else { return }
        let marker = changed
        if edit(ripple: false, { s throws(SessionError) in try s.setMarker(marker) }) != nil, open.field == .start {
            leadingPane.revealMarker = open.marker
        }
    }
}
