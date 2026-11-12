import AppKit
import DirigibleCore
import DirigibleTimeline
import SwiftUI

/// The list of the session index: a view-based `NSTableView` (a SwiftUI `List` of 12,250 rows took
/// 140 ms per search key). It reloads only when the shown rows change. One row can be selected,
/// and a click or a plain arrow runs the row action. A row is one accessibility element, the kind
/// first.
struct SessionIndexTable: NSViewRepresentable {
    static let nameColumn = NSUserInterfaceItemIdentifier("name")
    static let startColumn = NSUserInterfaceItemIdentifier("start")

    let model: SessionWindow
    let pane: LeadingPaneState
    let rows: [SessionIndex.Row]
    let rate: Int

    func makeCoordinator() -> IndexTableSource { IndexTableSource() }

    func makeNSView(context: Context) -> NSScrollView {
        let source = context.coordinator
        source.model = model
        source.pane = pane
        let table = IndexTableView()
        let name = NSTableColumn(identifier: Self.nameColumn)
        name.title = L10n.markerName.text
        name.resizingMask = .autoresizingMask
        name.minWidth = 60
        let start = NSTableColumn(identifier: Self.startColumn)
        start.title = L10n.indexColumnStart.text
        start.width = 84
        start.minWidth = 84
        start.maxWidth = 84
        start.resizingMask = []
        table.addTableColumn(name)
        table.addTableColumn(start)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.rowHeight = 22
        table.allowsMultipleSelection = false
        table.allowsColumnReordering = false
        table.allowsColumnResizing = false
        table.allowsTypeSelect = false
        table.style = .plain
        table.dataSource = source
        table.delegate = source
        table.setAccessibilityLabel(L10n.indexSegmentIndex.text)
        source.table = table
        table.beep = { [weak model] in model?.beep() }
        pane.table = table
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        table.mark.attach(to: table)
        source.observeLiveScroll(of: scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.model = model
        context.coordinator.show(rows, rate: rate)
    }
}

@MainActor final class IndexTableSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    weak var table: IndexTableView?
    weak var model: SessionWindow?
    weak var pane: LeadingPaneState?
    private(set) var rows: [SessionIndex.Row] = []
    private var rate = 48_000
    /// True while the table takes a selection that the window pushed: no row action runs then.
    private(set) var pushingRows = false
    /// The cell views that the table asked for, for the tests.
    private(set) var cellViews = 0
    /// The name field of the open row edit, and true while a reload removes it.
    weak var editing: NSTextField?
    var reloading = false

    /// A change of up to `SessionIndex.updateLimit` rows removes and inserts them; a larger one
    /// reloads the table. An open field whose row stays keeps its view, and the mark takes its new
    /// row; a removed field opens again with the text typed so far.
    func show(_ rows: [SessionIndex.Row], rate: Int) {
        guard rows != self.rows || rate != self.rate else { return }
        let change =
            rate == self.rate
            ? SessionIndex.change(from: self.rows, to: rows) : (old: 0..<self.rows.count, new: 0..<rows.count)
        (self.rows, self.rate) = (rows, rate)
        let reopening = editing != nil
        reloading = true
        if let table, change.old.count + change.new.count <= SessionIndex.updateLimit {
            table.beginUpdates()
            table.removeRows(at: IndexSet(integersIn: change.old), withAnimation: [])
            table.insertRows(at: IndexSet(integersIn: change.new), withAnimation: [])
            table.endUpdates()
        } else {
            table?.reloadData()
        }
        reloading = false
        showSelection()
        guard let table else { return }
        table.mark.show(rows, in: table)
        if let field = editing, field.window != nil {
            table.mark.edit(row: table.row(for: field), in: table)
        } else if reopening {
            openField(select: false)
        }
    }

    /// A live scroll of the list that moves it holds the index follow while play or a take runs.
    func observeLiveScroll(of scroll: NSScrollView) {
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(liveScrollStarted(_:)), name: NSScrollView.willStartLiveScrollNotification,
            object: scroll)
        center.addObserver(
            self, selector: #selector(liveScrollEnded(_:)), name: NSScrollView.didEndLiveScrollNotification,
            object: scroll)
    }

    @objc private func liveScrollStarted(_ note: Notification) {
        guard let scroll = note.object as? NSScrollView else { return }
        table?.mark.liveScrollStarted(at: scroll.contentView.bounds.minY)
    }

    @objc private func liveScrollEnded(_ note: Notification) {
        guard let scroll = note.object as? NSScrollView else { return }
        table?.mark.liveScrollEnded(at: scroll.contentView.bounds.minY)
    }

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

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("indexRow")
        let view = tableView.makeView(withIdentifier: id, owner: nil) as? IndexRowView ?? IndexRowView()
        view.identifier = id
        view.spoken = Self.spoken(rows[row], rate: rate)
        let item = rows[row]
        view.actions = [
            NSAccessibilityCustomAction(name: L10n.indexActionGoTo.text) { [weak self] in
                self?.model?.selectIndexRow(item, byClick: true)
                return true
            },
            NSAccessibilityCustomAction(name: L10n.indexActionShowInfo.text) { [weak self] in
                self?.model?.showIndexInfo(item)
                return true
            },
        ]
        if item.kind != .clip {
            view.actions.append(
                NSAccessibilityCustomAction(name: L10n.headerRename.text) { [weak self] in
                    self?.model?.renameIndexRow(item.id)
                    return true
                })
        }
        view.actions.append(
            NSAccessibilityCustomAction(name: L10n.indexActionPlayFromHere.text) { [weak self] in
                self?.model?.playFromIndexRow(item)
                return true
            })
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard let column else { return nil }
        cellViews += 1
        let id = column.identifier
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? IndexCell ?? IndexCell(identifier: id)
        let item = rows[row]
        if id == SessionIndexTable.nameColumn {
            cell.show(text: item.name, symbol: Self.symbol(item.kind))
        } else {
            cell.show(text: timeDisplayText(item.position, rate: rate, playing: false), symbol: nil)
        }
        return cell
    }

    static func symbol(_ kind: SessionIndex.Kind) -> String {
        switch kind {
        case .clip: "waveform"
        case .marker: "flag"
        case .chapter: "bookmark"
        }
    }

    /// The label of a row, the kind first: "Marker, Breath, 1 second" or "Clip, take, Host, 1 second".
    /// `text` gives the value of a key in the language of `locale`.
    static func spoken(
        _ row: SessionIndex.Row, rate: Int, locale: Locale = .current, text: (L10n) -> String = { $0.text }
    ) -> String {
        let time = spokenTime(row.position, rate: rate, locale: locale)
        func label(_ format: L10n, _ arguments: any CVarArg...) -> String {
            String(format: text(format), locale: locale, arguments: arguments)
        }
        switch row.item {
        case .clip(_, let track): return label(.indexRowLabelClip, text(.inspectorTabClip), row.name, track, time)
        case .marker: return label(.indexRowLabelMark, text(.inspectorTabMarker), row.name, time)
        case .chapter: return label(.indexRowLabelMark, text(.indexKindChapter), row.name, time)
        }
    }

    /// Whole hours, minutes, and seconds in words, each unit in the app language: "12 minutes 30
    /// seconds". A zero keeps only the seconds.
    static func spokenTime(_ frames: Frames, rate: Int, locale: Locale = .current) -> String {
        let total = frames.count / max(1, rate)
        let units: [(count: Int, unit: Duration.UnitsFormatStyle.Unit, seconds: Int)] = [
            (total / 3_600, .hours, 3_600), (total / 60 % 60, .minutes, 60), (total % 60, .seconds, 1),
        ]
        let shown = units.filter { $0.count > 0 }
        return (shown.isEmpty ? [units[2]] : shown)
            .map {
                let style = Duration.UnitsFormatStyle(
                    allowedUnits: [$0.unit], width: .wide, zeroValueUnits: .show(length: 1))
                return style.locale(locale).format(.seconds($0.count * $0.seconds))
            }
            .joined(separator: " ")
    }
}

/// The list view. A click runs the row action itself, so a click on the row that shows also acts.
/// The table does not call `super.mouseDown`, so `doubleAction` never fires: the second click of a
/// double click plays from the row here.
/// Shift-arrows, Shift-click, Command-click, Delete, and Select All beep: the list selects one row.
final class IndexTableView: NSTableView {
    var beep: () -> Void = {}
    let mark = IndexPlayMark()
    /// The calls of `reloadData`, for the tests.
    private(set) var reloads = 0

    override func reloadData() {
        reloads += 1
        super.reloadData()
    }

    override func layout() {
        super.layout()
        mark.place(in: self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        mark.restyle(effectiveAppearance)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.control) { return super.mouseDown(with: event) }
        window?.makeFirstResponder(self)
        if !flags.isDisjoint(with: [.shift, .command]) { return beep() }
        let n = row(at: convert(event.locationInWindow, from: nil))
        if n >= 0 { (dataSource as? IndexTableSource)?.click(row: n, clickCount: event.clickCount) }
    }

    override func keyDown(with event: NSEvent) {
        let arrow = event.keyCode == 125 || event.keyCode == 126
        if arrow, event.modifierFlags.contains(.shift) { return beep() }
        // F2 has no menu item.
        if event.keyCode == 120 {
            (dataSource as? IndexTableSource)?.model?.renameSelectedIndexRow()
            return
        }
        // The route from the table up through the window does not run the item of Space, as it does
        // for J, K, L, N, and H: the table asks the main menu itself.
        if event.keyCode == 49, NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        (dataSource as? IndexTableSource)?.rowMenu(at: row(at: convert(event.locationInWindow, from: nil)))
    }

    @objc func delete(_ sender: Any?) { beep() }

    override func selectAll(_ sender: Any?) { beep() }
}
