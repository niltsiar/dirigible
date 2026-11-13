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
    var pushingRows = false
    /// The cell views that the table asked for, for the tests.
    private(set) var cellViews = 0
    /// The name field of the open row edit, and true while a reload removes it.
    weak var editing: NSTextField?
    var reloading = false

    /// A change of up to `SessionIndex.updateLimit` row IDs removes and inserts them, and each
    /// other row view shows its new name and start. A larger change that drops no row view keeps each
    /// row view at its place and shows the new row of that place in it; a larger change that drops one,
    /// or a new rate, reloads the table. An open field whose row stays keeps its view, and the mark
    /// takes its new row; a removed or reloaded field opens again with the text typed so far. A new
    /// name of the edited marker (an agent edit) replaces the typed text, as in the Name field of the
    /// inspector.
    func show(_ rows: [SessionIndex.Row], rate: Int) { timePart(pane, "show") { showRows(rows, rate: rate) } }

    private func showRows(_ rows: [SessionIndex.Row], rate: Int) {
        guard timePart(pane, "show compare", { rows != self.rows || rate != self.rate }) else { return }
        let old = self.rows
        let change = timePart(pane, "show change") {
            rate == self.rate ? SessionIndex.change(from: old, to: rows) : nil
        }
        (self.rows, self.rate) = (rows, rate)
        timePart(pane, "show echo") {
            if let edit = pane?.rowEdit, let was = old.first(where: { $0.id == .marker(edit.marker) })?.name,
                let name = rows.first(where: { $0.id == .marker(edit.marker) })?.name, name != was
            {
                pane?.rowEdit?.text = name
            }
        }
        let reopening = editing != nil
        reloading = true
        timePart(pane, "show table") {
            guard let table else { return }
            if let change, change.old.count + change.new.count <= SessionIndex.updateLimit {
                table.beginUpdates()
                table.removeRows(at: IndexSet(integersIn: change.old), withAnimation: [])
                table.insertRows(at: IndexSet(integersIn: change.new), withAnimation: [])
                table.endUpdates()
                refreshRows(of: table, from: old, change: change)
            } else if change != nil, Self.lastRowView(of: table) < rows.count {
                // The table keeps the row views and makes the new rows in view from `rows`. A row view
                // that this call drops stays in the table as a subview for good, so a drop reloads.
                table.noteNumberOfRowsChanged()
                // After a `reloadData`, the call can keep the old frame, and a scroll to a row past it
                // stops at the old end.
                table.tile()
                refreshRows(of: table, from: old, change: nil)
            } else {
                table.reloadData()
            }
        }
        reloading = false
        timePart(pane, "show selection") { showSelection() }
        guard let table else { return }
        timePart(pane, "show mark") { table.mark.show(rows, in: table) }
        if let field = editing, field.currentEditor() != nil {
            table.mark.edit(row: table.row(for: field), in: table)
        } else if reopening {
            openField(select: false)
        }
    }

    /// Each row view that the table holds outside `change.new` shows the row of `old` at its old
    /// place, or with no `change` at its own place: its cells take the new row in place. A reload of a
    /// cell ends the field editor of its row, so only the name cell of the open field loads again, and
    /// only when its row takes another item, name, or kind; the field opens again on its marker row.
    private func refreshRows(
        of table: NSTableView, from old: [SessionIndex.Row], change: (old: Range<Int>, new: Range<Int>)?
    ) {
        let name = table.column(withIdentifier: SessionIndexTable.nameColumn)
        let start = table.column(withIdentifier: SessionIndexTable.startColumn)
        var field: Int?
        table.enumerateAvailableRowViews { view, n in
            let w = change.map { n < $0.new.lowerBound ? n : n - $0.new.upperBound + $0.old.upperBound } ?? n
            guard change?.new.contains(n) != true, old.indices.contains(w), let view = view as? IndexRowView else {
                return
            }
            let (was, row) = (old[w], rows[n])
            guard was != row else { return }
            configure(view, row: n)
            if was.id != row.id || was.name != row.name || was.kind != row.kind,
                let cell = table.view(atColumn: name, row: n, makeIfNecessary: false) as? IndexCell
            {
                if editing?.superview === cell {
                    field = n
                } else {
                    cell.show(text: row.name, symbol: Self.symbol(row.kind))
                }
            }
            if was.position != row.position,
                let cell = table.view(atColumn: start, row: n, makeIfNecessary: false) as? IndexCell
            {
                cell.show(text: timeDisplayText(row.position, rate: rate, playing: false), symbol: nil)
            }
        }
        if let field { table.reloadData(forRowIndexes: [field], columnIndexes: [name]) }
    }

    private static func lastRowView(of table: NSTableView) -> Int {
        var last = -1
        table.enumerateAvailableRowViews { _, n in last = max(last, n) }
        return last
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

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("indexRow")
        let view = tableView.makeView(withIdentifier: id, owner: nil) as? IndexRowView ?? IndexRowView()
        view.identifier = id
        configure(view, row: row)
        return view
    }

    /// The label and the actions of row `row`.
    private func configure(_ view: IndexRowView, row: Int) {
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
        timePart((dataSource as? IndexTableSource)?.pane, "table layout") { super.layout() }
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
