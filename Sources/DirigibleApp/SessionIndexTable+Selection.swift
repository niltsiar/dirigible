import AppKit
import DirigibleCore
import DirigibleTimeline

extension IndexTableSource {
    /// Runs a mouse or key handler of the table. The rows that it writes show at once, so their push
    /// does not scroll the list to the anchor.
    func fromList<T>(_ body: () -> T) -> T {
        listWrite = true
        defer { listWrite = false }
        return body()
    }

    /// Shows the pushed rows: each shown row that is selected, in one pass. A push from outside the
    /// list (a lane write, the row after a Delete) scrolls to the anchor row when it is shown, else to the
    /// first selected row, and sets the end of a Shift range back to the anchor.
    func showSelection() {
        guard let table, let pane else { return }
        let (selected, anchor) = (pane.pushedRows, pane.pushedAnchor)
        pushingRows = true
        defer { pushingRows = false }
        if !listWrite { movedEnd = nil }
        var target = IndexSet()
        var anchored: Int?
        if !selected.isEmpty {
            for (n, row) in rows.enumerated() where selected.contains(row.id) {
                target.insert(n)
                if row.id == anchor { anchored = n }
            }
        }
        guard let first = target.first else {
            table.deselectAll(nil)
            return
        }
        if table.selectedRowIndexes != target { table.selectRowIndexes(target, byExtendingSelection: false) }
        if !listWrite { table.scrollRowToVisible(anchored ?? first) }
    }

    /// A click on row `n`. A plain click: the table takes it and the row action runs, also for the row
    /// that shows already. Shift extends the rows from the anchor, and Command toggles the row; neither seeks.
    func click(row n: Int, clickCount: Int = 1, flags: NSEvent.ModifierFlags = []) {
        guard let table, rows.indices.contains(n) else { return }
        if flags.contains(.shift) { return extend(to: n) }
        if flags.contains(.command) { return toggle(n) }
        movedEnd = nil
        pushingRows = true
        table.selectRowIndexes([n], byExtendingSelection: false)
        pushingRows = false
        model?.selectIndexRow(rows[n], byClick: true)
        if clickCount == 2 { model?.playFromIndexRow(rows[n], selecting: false) }
    }

    /// Command-A: every row that the filter shows.
    func selectAll() {
        movedEnd = nil
        model?.selectAllIndexRows()
    }

    /// Shift-Down Arrow and Shift-Up Arrow: the range from the anchor to the end, which moves one row.
    func extend(down: Bool) {
        guard let model, let anchor = model.timeline.anchorRow, let from = index(of: anchor) else {
            model?.beep()
            return
        }
        let end = movedEnd.flatMap(index(of:)) ?? from
        let moved = min(max(end + (down ? 1 : -1), 0), rows.count - 1)
        write(range(from, moved), anchor: anchor)
        movedEnd = rows[moved].id
        table?.scrollRowToVisible(moved)
    }

    private func extend(to n: Int) {
        guard let model else { return }
        guard let anchor = model.timeline.anchorRow, let from = index(of: anchor) else {
            write([rows[n].id], anchor: rows[n].id)
            movedEnd = rows[n].id
            return
        }
        write(range(from, n), anchor: anchor)
        movedEnd = rows[n].id
    }

    private func toggle(_ n: Int) {
        guard let model else { return }
        let pick = rows[n].id
        var picks = model.timeline.selectedRows
        var anchor = model.timeline.anchorRow
        if picks.remove(pick) == nil {
            picks.insert(pick)
            anchor = pick
        } else if anchor.map(picks.contains) != true {
            anchor = rows.first { picks.contains($0.id) }?.id
        }
        movedEnd = nil
        write(picks, anchor: anchor)
    }

    private func index(of pick: SessionIndex.Pick) -> Int? { rows.firstIndex { $0.id == pick } }

    private func range(_ a: Int, _ b: Int) -> Set<SessionIndex.Pick> { Set(rows[min(a, b)...max(a, b)].map(\.id)) }

    private func write(_ picks: Set<SessionIndex.Pick>, anchor: SessionIndex.Pick?) {
        model?.timeline.selectRows(picks, anchor: anchor, form: .indexSet)
    }

    /// An arrow key moved the row. A selection of several rows that AppKit makes itself goes in as
    /// rows with no seek. A selection that a table update moves is no key.
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !pushingRows, !reloading, let table, let model else { return }
        movedEnd = nil
        let picked = table.selectedRowIndexes
        if picked.count > 1 {
            let picks = Set(picked.compactMap { rows.indices.contains($0) ? rows[$0].id : nil })
            let anchor =
                model.timeline.anchorRow.flatMap { picks.contains($0) ? $0 : nil } ?? rows[picked.first ?? 0].id
            return write(picks, anchor: anchor)
        }
        guard rows.indices.contains(table.selectedRow) else { return }
        model.selectIndexRow(rows[table.selectedRow], byClick: false)
    }
}
