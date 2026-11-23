import AppKit
import DirigibleAudio
import DirigibleCore
import SwiftUI

/// The list of the Bins segment (F22): a view-based `NSTableView`, as the index list. A bin is a group
/// row; only an item row selects. Type-to-select is off, so a plain key reaches its menu item (C29).
struct BinsTable: NSViewRepresentable {
    static let column = NSUserInterfaceItemIdentifier("bins")

    let model: SessionWindow
    let rows: [BinsRow]
    let rate: Int

    func makeCoordinator() -> BinsTableSource { BinsTableSource() }

    func makeNSView(context: Context) -> NSScrollView {
        let source = context.coordinator
        source.model = model
        let table = BinsTableView()
        let column = NSTableColumn(identifier: Self.column)
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.rowHeight = 22
        table.allowsTypeSelect = false
        table.allowsMultipleSelection = false
        table.style = .plain
        table.dataSource = source
        table.delegate = source
        table.target = source
        table.doubleAction = #selector(BinsTableSource.doubleClicked(_:))
        table.setAccessibilityLabel(L10n.indexSegmentBins.text)
        source.table = table
        model.leadingPane.binsTable = table
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        source.update(rows: rows, rate: rate)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(rows: rows, rate: rate)
    }
}

/// The table of the Bins list. The Edit selectors stop here, so `UndoRoutingWindow` never runs them
/// on the lanes while the list has the focus (C23).
final class BinsTableView: NSTableView {
    var source: BinsTableSource? { dataSource as? BinsTableSource }

    /// A rename that opened while the pane was hidden gets its field when the list joins the window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { source?.openField() }
    }

    /// The table route does not run the item of Space, as it does for J, K, and L: the table asks the
    /// main menu itself, as the index list does.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49, NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        source?.contextMenu(row: row(at: convert(event.locationInWindow, from: nil)))
    }

    @objc func delete(_ sender: Any?) { _ = source?.model?.binsCommand(.delete, isKey: false) }
    @objc func cut(_ sender: Any?) { source?.model?.beep() }
    @objc func copy(_ sender: Any?) { source?.model?.beep() }
    @objc func paste(_ sender: Any?) { source?.model?.beep() }
}

/// The rows, the cells, the selection, the context menu, and the rename field of the Bins list.
@MainActor final class BinsTableSource: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    weak var model: SessionWindow?
    weak var table: NSTableView?
    private(set) var rows: [BinsRow] = []
    private var rate = 48_000
    /// The field of the open rename.
    private weak var field: BinNameField?
    private var updating = false

    func update(rows: [BinsRow], rate: Int) {
        guard rows != self.rows || rate != self.rate, let table else { return }
        (self.rows, self.rate) = (rows, rate)
        // An undo, an agent edit, or a store edit can remove the selected item or the row of the open
        // rename.
        if let model {
            if let pick = model.leadingPane.selectedBinItem, !rows.contains(where: { $0.pick == pick }) {
                model.leadingPane.selectedBinItem = nil
            }
            if let target = model.leadingPane.binRename, row(of: target) == nil { model.finishBinRename(save: false) }
        }
        // A reload and the reselect write no selection of the pane.
        updating = true
        table.reloadData()
        showSelection()
        updating = false
        if model?.leadingPane.binRename != nil { openField() }
    }

    /// Selects the row of the selected item of the pane, or no row. The deselect keeps the item of the
    /// pane: the row of a new item comes at the next update.
    func showSelection() {
        guard let table else { return }
        if let pick = model?.leadingPane.selectedBinItem, let row = rows.firstIndex(where: { $0.pick == pick }) {
            if table.selectedRow != row { table.selectRowIndexes([row], byExtendingSelection: false) }
            table.scrollRowToVisible(row)
        } else if table.selectedRow != -1 {
            let outer = updating
            updating = true
            table.deselectAll(nil)
            updating = outer
        }
    }

    private func row(of target: BinRename) -> Int? { rows.firstIndex { $0.rename == target } }

    /// Opens the name field of the rename of the pane, with its whole text selected. A row that is not
    /// in the list yet opens at the next update.
    func openField() {
        guard let table, table.window != nil, let target = model?.leadingPane.binRename,
            field?.currentEditor() == nil, let row = row(of: target)
        else { return }
        table.scrollRowToVisible(row)
        // The row view joins the table at its layout, and only a field in the window takes the focus.
        table.layoutSubtreeIfNeeded()
        guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
            let field = cell.textField as? BinNameField
        else { return }
        field.isEditable = true
        field.delegate = self
        self.field = field
        table.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    /// Ends the name field and gives the focus back to the list. The result is the typed text.
    func closeField() -> String? {
        guard let field else { return nil }
        let text = field.currentEditor()?.string ?? field.stringValue
        self.field = nil
        field.abortEditing()
        field.isEditable = false
        field.delegate = nil
        if let table { table.window?.makeFirstResponder(table) }
        return text
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): model?.finishBinRename(save: true)
        case #selector(NSResponder.cancelOperation(_:)): model?.finishBinRename(save: false)
        default: return false
        }
        return true
    }

    /// A focus loss of the open field keeps the typed name. The table also forwards the end of other
    /// editing to its delegate, so only the open field in the window counts.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let open = field, notification.object as? BinNameField === open, open.window != nil,
            open.currentEditor() == nil
        else { return }
        model?.finishBinRename(save: true)
    }

    // MARK: Rows

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    /// A bin of the session and the Favorites header are group rows. A store group is a plain row
    /// under the header, so the section has one group level.
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        switch rows[row] {
        case .bin, .favoritesHeader: true
        case .item, .favoriteGroup, .favorite, .favoritesNote: false
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { rows[row].pick != nil }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .favoritesNote(let fault) = rows[row] { FavoritesNoteCell.height(fault) } else { tableView.rowHeight }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .bin(let bin): BinHeaderCell(bin.name)
        case .favoritesHeader: BinHeaderCell(L10n.favoritesTitle.text)
        case .favoriteGroup(let bin): BinHeaderCell(bin.name, indent: 12)
        case .item(let item, let fault): itemCell(item, rate: rate, fault: fault, pick: .session(item.id))
        case .favorite(let item, let rate): itemCell(item, rate: rate, fault: nil, pick: .favorite(item.id))
        case .favoritesNote(let fault): FavoritesNoteCell(fault)
        }
    }

    private func itemCell(_ item: BinItem, rate: Int, fault: MediaFault?, pick: BinsPick) -> BinItemCell {
        let cell = BinItemCell()
        cell.show(item, rate: rate, fault: fault)
        cell.actions = { [weak self] in self?.itemActions(pick) ?? [] }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table, let model, !updating else { return }
        let row = table.selectedRow
        model.leadingPane.selectedBinItem = row >= 0 ? rows[row].pick : nil
    }

    // MARK: Actions

    @objc func doubleClicked(_ sender: Any?) {
        guard let table, table.clickedRow >= 0, let pick = rows[table.clickedRow].pick else { return }
        model?.perform(.paste, on: pick)
    }

    /// The row menu: Paste at Playhead, Insert at Playhead, Rename, and Delete for an item or a
    /// favorite; Rename and Delete for a bin or a store group. Each item does what its key does (C23).
    func contextMenu(row: Int) -> NSMenu? {
        guard rows.indices.contains(row) else { return nil }
        let menu = NSMenu()
        switch rows[row] {
        case .item(let item, _): itemMenu(menu, .session(item.id))
        case .favorite(let item, _): itemMenu(menu, .favorite(item.id))
        case .bin(let bin):
            menu.addItem(MenuAction(L10n.binsRename.text) { [weak self] in self?.model?.beginBinRename(.bin(bin.id)) })
            menu.addItem(MenuAction(L10n.binsRemove.text) { [weak self] in self?.model?.removeBin(bin.id) })
        case .favoriteGroup(let bin):
            menu.addItem(
                MenuAction(L10n.binsRename.text) { [weak self] in self?.model?.beginBinRename(.favoriteBin(bin.id)) })
            menu.addItem(MenuAction(L10n.binsRemove.text) { [weak self] in self?.model?.removeFavoriteGroup(bin.id) })
        case .favoritesHeader, .favoritesNote: return nil
        }
        return menu
    }

    private func itemMenu(_ menu: NSMenu, _ pick: BinsPick) {
        model?.selectBinItem(pick)
        for action in itemActions(pick) { menu.addItem(MenuAction(action.name) { _ = action.handler?() }) }
        menu.addItem(MenuAction(L10n.binsRemove.text) { [weak self] in self?.model?.perform(.remove, on: pick) })
    }

    /// Paste at Playhead, Insert at Playhead, and Rename: the row menu and the VoiceOver actions (C30).
    func itemActions(_ pick: BinsPick) -> [NSAccessibilityCustomAction] {
        [(L10n.binsPaste, BinsAction.paste), (.binsInsert, .insert), (.binsRename, .rename)].map { name, action in
            NSAccessibilityCustomAction(name: name.text) { [weak self] in
                self?.model?.perform(action, on: pick)
                return true
            }
        }
    }
}
