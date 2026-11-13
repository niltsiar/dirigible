import AppKit
import DirigibleCore
import DirigibleTimeline

/// The name field and the time field of a marker or chapter row, and the row menu. The state of the
/// field is `LeadingPaneState.rowEdit`: the field view shows it, and `SessionWindow.finishRowEdit` ends it.
extension IndexTableSource: NSTextFieldDelegate, NSMenuDelegate {
    /// The column of the field of an edit: Name or Start.
    private func column(of edit: LeadingPaneState.RowEdit) -> Int {
        table?.column(
            withIdentifier: edit.field == .name ? SessionIndexTable.nameColumn : SessionIndexTable.startColumn) ?? 0
    }

    /// Shows the open row edit in the cell of its row. A reload that removed the field opens it
    /// again with the text typed so far. A row that is gone from the session ends the edit with no
    /// commit. A row that the list does not show yet (a marker just added) waits: `show` opens the
    /// field when the row first shows.
    func openField(select: Bool) {
        guard let table, let pane, let edit = pane.rowEdit else { return }
        guard let row = rows.firstIndex(where: { $0.id == .marker(edit.marker) }) else {
            if model?.studio?.session.markers[edit.marker] == nil { model?.finishRowEdit(save: false) }
            return
        }
        table.scrollRowToVisible(row)
        let column = column(of: edit)
        guard let cell = table.view(atColumn: column, row: row, makeIfNecessary: true) as? IndexCell else { return }
        let field = cell.beginEditing(
            text: edit.text, accessibility: (edit.field == .name ? L10n.markerName : L10n.indexColumnStart).text,
            delegate: self)
        editing = field
        table.window?.makeFirstResponder(field)
        field.currentEditor()?.selectedRange =
            select
            ? NSRange(location: 0, length: edit.text.utf16.count) : NSRange(location: edit.text.utf16.count, length: 0)
        table.mark.edit(row: row, in: table)
        table.mark.hold(.rowField, open: true)
    }

    /// Takes the field off the row. The focus goes back to the list when the field still has it.
    func closeField() {
        guard let table, let field = editing else { return }
        editing = nil
        let focused = field.currentEditor() != nil
        if focused { table.window?.makeFirstResponder(table) }
        let column = table.column(for: field)
        (field.superview as? IndexCell)?.endEditing()
        table.mark.edit(row: nil, in: table)
        table.mark.hold(.rowField, open: false)
        let row = table.row(for: field)
        if row >= 0, column >= 0 { table.reloadData(forRowIndexes: [row], columnIndexes: [column]) }
    }

    func controlTextDidChange(_ note: Notification) {
        guard let field = note.object as? NSTextField, field === editing else { return }
        pane?.rowEdit?.text = field.currentEditor()?.string ?? field.stringValue
    }

    /// A focus loss: the field ends, and the typed name is saved.
    func controlTextDidEndEditing(_ note: Notification) {
        guard !reloading, let field = note.object as? NSTextField, field === editing, field.window != nil else {
            return
        }
        pane?.rowEdit?.text = field.stringValue
        model?.rowFieldLostFocus()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === editing else { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): model?.finishRowEdit(save: true, strict: true)
        case #selector(NSResponder.insertTab(_:)): move(by: 1)
        case #selector(NSResponder.insertBacktab(_:)): move(by: -1)
        case #selector(NSResponder.cancelOperation(_:)): model?.finishRowEdit(save: false)
        default: return false
        }
        return true
    }

    /// Tab and Shift-Tab run the fields in this order: the name and the time of each marker or chapter
    /// row, which skips the clip rows. The target is picked from the rows as they show now, before the
    /// commit moves a row. The typed value is saved, and the field opens on the target. At the end the
    /// field ends.
    private func move(by step: Int) {
        guard let model, let edit = pane?.rowEdit,
            let here = rows.firstIndex(where: { $0.id == .marker(edit.marker) })
        else { return }
        let names = rows.indices.filter { rows[$0].kind != .clip }
        let neighbor = step > 0 ? names.first { $0 > here } : names.last { $0 < here }
        let target: (row: Int, field: LeadingPaneState.RowEdit.Field)?
        switch (edit.field, step > 0) {
        case (.name, true): target = (here, .start)
        case (.start, false): target = (here, .name)
        case (.start, true): target = neighbor.map { ($0, .name) }
        case (.name, false): target = neighbor.map { ($0, .start) }
        }
        let pick = target.map { rows[$0.row].id }
        guard model.finishRowEdit(save: true, strict: true), let target, let pick, case .marker(let id) = pick
        else { return }
        if target.row != here { model.timeline.selectRows([pick], anchor: pick) }
        model.beginRowEdit(id, field: target.field)
    }

    /// The menu of a row: Rename on a marker or chapter row, and Play from Here on each row.
    func rowMenu(at row: Int) -> NSMenu? {
        guard rows.indices.contains(row) else { return nil }
        let menu = NSMenu()
        func add(_ title: L10n, _ action: Selector) {
            let item = NSMenuItem(title: title.text, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = rows[row].id
            menu.addItem(item)
        }
        if rows[row].kind != .clip { add(.headerRename, #selector(renameFromMenu(_:))) }
        add(.indexMenuPlayFromHere, #selector(playFromMenu(_:)))
        menu.delegate = self
        return menu
    }

    @objc private func renameFromMenu(_ item: NSMenuItem) {
        if let pick = item.representedObject as? SessionIndex.Pick { model?.renameIndexRow(pick) }
    }

    @objc private func playFromMenu(_ item: NSMenuItem) {
        if let pick = item.representedObject as? SessionIndex.Pick, let row = rows.first(where: { $0.id == pick }) {
            model?.playFromIndexRow(row)
        }
    }

    func menuWillOpen(_ menu: NSMenu) { table?.mark.hold(.rowMenu, open: true) }

    func menuDidClose(_ menu: NSMenu) { table?.mark.hold(.rowMenu, open: false) }
}
