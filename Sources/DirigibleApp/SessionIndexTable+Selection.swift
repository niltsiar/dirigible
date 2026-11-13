import AppKit
import DirigibleCore
import DirigibleTimeline

extension IndexTableSource {
    /// Shows the pushed rows: the anchor row when it is selected and shown, else the first shown
    /// selected row, else nothing. A table holds one selected row.
    func showSelection() {
        guard let table, let pane else { return }
        let (selected, anchor) = (pane.pushedRows, pane.pushedAnchor)
        let anchored = anchor.flatMap { pick in selected.contains(pick) ? rows.firstIndex { $0.id == pick } : nil }
        let shown = selected.isEmpty ? nil : anchored ?? rows.firstIndex { selected.contains($0.id) }
        pushingRows = true
        defer { pushingRows = false }
        guard let shown else {
            table.deselectAll(nil)
            return
        }
        table.selectRowIndexes([shown], byExtendingSelection: false)
        table.scrollRowToVisible(shown)
    }

    /// A click on row `n`: the table takes it and the row action runs, also for the row that
    /// shows already.
    func click(row n: Int, clickCount: Int = 1) {
        guard let table, rows.indices.contains(n) else { return }
        pushingRows = true
        table.selectRowIndexes([n], byExtendingSelection: false)
        pushingRows = false
        model?.selectIndexRow(rows[n], byClick: true)
        if clickCount == 2 { model?.playFromIndexRow(rows[n], selecting: false) }
    }

    /// An arrow key moved the row.
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !pushingRows, let table, rows.indices.contains(table.selectedRow) else { return }
        model?.selectIndexRow(rows[table.selectedRow], byClick: false)
    }
}
