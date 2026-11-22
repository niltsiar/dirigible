import AppKit
import DirigibleCore
import SwiftUI

/// A row of the Bins list: the header of a bin, or an item with the missing-file state of its clips.
enum BinsRow: Hashable {
    case bin(Bin)
    case item(BinItem, missing: Bool)

    /// The rows of `bins` in user order: each bin, then its items.
    static func rows(_ bins: [Bin], missing: Set<FileID>) -> [BinsRow] {
        bins.flatMap { bin in
            [.bin(bin)]
                + bin.items.map { item in
                    .item(item, missing: item.lanes.contains { $0.clips.contains { missing.contains($0.file) } })
                }
        }
    }
}

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
        // An undo or an agent edit can remove the selected item or the row of the open rename.
        if let model {
            if let id = model.leadingPane.selectedBinItem, row(of: .item(id)) == nil {
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
        let id = model?.leadingPane.selectedBinItem
        if let row = rows.firstIndex(where: { if case .item(let item, _) = $0 { item.id == id } else { false } }) {
            if table.selectedRow != row { table.selectRowIndexes([row], byExtendingSelection: false) }
            table.scrollRowToVisible(row)
        } else if table.selectedRow != -1 {
            let outer = updating
            updating = true
            table.deselectAll(nil)
            updating = outer
        }
    }

    private func row(of target: BinRename) -> Int? {
        rows.firstIndex {
            switch ($0, target) {
            case (.bin(let bin), .bin(let id)): bin.id == id
            case (.item(let item, _), .item(let id)): item.id == id
            default: false
            }
        }
    }

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

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .bin = rows[row] { true } else { false }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        !self.tableView(tableView, isGroupRow: row)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .bin(let bin):
            let cell = BinHeaderCell()
            cell.textField?.stringValue = bin.name
            return cell
        case .item(let item, let missing):
            let cell = BinItemCell()
            cell.show(item, rate: rate, missing: missing)
            cell.actions = { [weak self] in self?.itemActions(item.id) ?? [] }
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table, let model, !updating else { return }
        let row = table.selectedRow
        if row >= 0, case .item(let item, _) = rows[row] {
            model.leadingPane.selectedBinItem = item.id
        } else {
            model.leadingPane.selectedBinItem = nil
        }
    }

    // MARK: Actions

    @objc func doubleClicked(_ sender: Any?) {
        guard let table, table.clickedRow >= 0, case .item(let item, _) = rows[table.clickedRow] else { return }
        model?.pasteBinItem(item.id, insert: false)
    }

    /// The row menu: Paste at Playhead, Insert at Playhead, Rename, and Delete for an item; Rename and
    /// Delete for a bin. Each item does what its key does (C23).
    func contextMenu(row: Int) -> NSMenu? {
        guard rows.indices.contains(row) else { return nil }
        let menu = NSMenu()
        switch rows[row] {
        case .item(let item, _):
            model?.selectBinItem(item.id)
            for action in itemActions(item.id) { menu.addItem(MenuAction(action.name) { _ = action.handler?() }) }
            menu.addItem(MenuAction(L10n.binsRemove.text) { [weak self] in self?.model?.removeBinItem(item.id) })
        case .bin(let bin):
            menu.addItem(MenuAction(L10n.binsRename.text) { [weak self] in self?.model?.beginBinRename(.bin(bin.id)) })
            menu.addItem(MenuAction(L10n.binsRemove.text) { [weak self] in self?.model?.removeBin(bin.id) })
        }
        return menu
    }

    /// Paste at Playhead, Insert at Playhead, and Rename: the row menu and the VoiceOver actions (C30).
    func itemActions(_ id: BinItemID) -> [NSAccessibilityCustomAction] {
        [
            NSAccessibilityCustomAction(name: L10n.binsPaste.text) { [weak self] in
                self?.model?.pasteBinItem(id, insert: false)
                return true
            },
            NSAccessibilityCustomAction(name: L10n.binsInsert.text) { [weak self] in
                self?.model?.pasteBinItem(id, insert: true)
                return true
            },
            NSAccessibilityCustomAction(name: L10n.binsRename.text) { [weak self] in
                self?.model?.selectBinItem(id)
                self?.model?.beginBinRename(.item(id))
                return true
            },
        ]
    }
}

/// A menu item that runs a closure.
final class MenuAction: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { run() }
}

/// The name field of a row: it takes text only while a rename is open.
final class BinNameField: NSTextField {
    convenience init(bold: Bool) {
        self.init(labelWithString: "")
        isEditable = false
        isBordered = false
        drawsBackground = false
        lineBreakMode = .byTruncatingTail
        font = bold ? .boldSystemFont(ofSize: NSFont.smallSystemFontSize) : .systemFont(ofSize: NSFont.systemFontSize)
        translatesAutoresizingMaskIntoConstraints = false
    }
}

/// The row of a bin: its name.
final class BinHeaderCell: NSTableCellView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        let name = BinNameField(bold: true)
        addSubview(name)
        textField = name
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            name.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// The row of an item: the name, the length in the time format of the ruler, and the missing-file
/// mark of the timeline clips (C24, C32). It reads no peaks. VoiceOver reads it as one element with
/// three actions (C30).
final class BinItemCell: NSTableCellView {
    let length = NSTextField(labelWithString: "")
    let missing = NSImageView()
    var actions: () -> [NSAccessibilityCustomAction] = { [] }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let name = BinNameField(bold: false)
        textField = name
        length.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        length.textColor = .secondaryLabelColor
        missing.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        missing.contentTintColor = .systemRed
        missing.toolTip = L10n.binsMissing.text
        for view in [name, length, missing] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.setAccessibilityElement(false)
            addSubview(view)
        }
        length.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            missing.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            missing.centerYAnchor.constraint(equalTo: centerYAnchor),
            missing.widthAnchor.constraint(equalToConstant: 14),
            name.leadingAnchor.constraint(equalTo: missing.trailingAnchor, constant: 4),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            length.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 6),
            length.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            length.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ item: BinItem, rate: Int, missing isMissing: Bool) {
        textField?.stringValue = item.name
        length.stringValue = rulerLabel(Double(item.length.count) / Double(rate), tenths: false)
        missing.isHidden = !isMissing
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .cell }
    override func accessibilityChildren() -> [Any]? { nil }

    override func accessibilityLabel() -> String? {
        "\(textField?.stringValue ?? ""), \(length.stringValue)"
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? { actions() }
}
