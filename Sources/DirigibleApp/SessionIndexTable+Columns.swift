import AppKit
import DirigibleCore
import DirigibleTimeline

/// The columns of the index list. Name and Start always show; the app preference `indexColumns`
/// shows Track, Duration, and End, in the same state in each window.
extension SessionIndexTable {
    static let trackColumn = NSUserInterfaceItemIdentifier("track")
    static let durationColumn = NSUserInterfaceItemIdentifier("duration")
    static let endColumn = NSUserInterfaceItemIdentifier("end")

    /// The width of a time column: the widest time, which has two hour digits, and 12 pt for the
    /// cell insets and the bezel of the time field, so the open field shows the whole time.
    static let timeWidth: CGFloat = {
        let widest = NSTextField(labelWithString: "00:00:00.000").attributedStringValue.size().width
        return ceil(widest) + 12
    }()
    static let trackWidth: CGFloat = 96

    static func identifier(of column: IndexColumns.Column) -> NSUserInterfaceItemIdentifier {
        switch column {
        case .track: trackColumn
        case .duration: durationColumn
        case .end: endColumn
        }
    }

    static func title(of column: IndexColumns.Column) -> L10n {
        switch column {
        case .track: .indexColumnTrack
        case .duration: .indexColumnDuration
        case .end: .indexColumnEnd
        }
    }

    /// The column of an optional column, hidden: `IndexTableSource.apply` shows it.
    static func makeColumn(_ column: IndexColumns.Column) -> NSTableColumn {
        fixedColumn(
            identifier(of: column), title: title(of: column), width: column == .track ? trackWidth : timeWidth,
            hidden: true)
    }

    static func fixedColumn(
        _ id: NSUserInterfaceItemIdentifier, title: L10n, width: CGFloat, hidden: Bool = false
    ) -> NSTableColumn {
        let column = NSTableColumn(identifier: id)
        column.title = title.text
        column.width = width
        column.minWidth = width
        column.maxWidth = width
        column.resizingMask = []
        column.isHidden = hidden
        return column
    }

    /// The text of the cell of `row` in a column other than Name. Duration and End are empty for a
    /// marker, and Track for a marker and a chapter.
    static func text(of row: SessionIndex.Row, in column: NSUserInterfaceItemIdentifier, rate: Int) -> String {
        func time(_ frames: Frames) -> String { timeDisplayText(frames, rate: rate, playing: false) }
        switch column {
        case durationColumn: return row.duration.map(time) ?? ""
        case endColumn: return row.duration.map { time(row.position + $0) } ?? ""
        case trackColumn:
            if case .clip(_, let track) = row.item { return track }
            return ""
        default: return time(row.position)
        }
    }

    /// True when `was` and `row` give another text in `column`.
    static func changed(
        _ column: NSUserInterfaceItemIdentifier, from was: SessionIndex.Row, to row: SessionIndex.Row
    ) -> Bool {
        switch column {
        case durationColumn: was.duration != row.duration
        case endColumn: was.position != row.position || was.duration != row.duration
        case trackColumn: was.item != row.item
        default: was.position != row.position
        }
    }
}

extension IndexTableSource {
    /// Shows the optional columns of `columns` and hides the others.
    func apply(_ columns: IndexColumns) {
        guard let table else { return }
        var changed = false
        for column in IndexColumns.Column.allCases {
            let id = SessionIndexTable.identifier(of: column)
            let hidden = !columns.shown.contains(column)
            guard let tableColumn = table.tableColumn(withIdentifier: id), tableColumn.isHidden != hidden else {
                continue
            }
            tableColumn.isHidden = hidden
            changed = true
            // AppKit keeps the cells of a hidden column, and they miss the changes that came meanwhile.
            if !hidden {
                table.reloadData(
                    forRowIndexes: IndexSet(integersIn: 0..<table.numberOfRows),
                    columnIndexes: [table.column(withIdentifier: id)])
            }
        }
        // A hidden column leaves the table at its old width and the first column with the freed room.
        if changed { table.sizeToFit() }
    }

    /// The menu of a Control-click or a right-click on a column header: one item for each optional
    /// column, checked when it shows.
    func headerMenu() -> NSMenu {
        let menu = NSMenu()
        let shown = model?.app?.indexColumns.shown ?? []
        for column in IndexColumns.Column.allCases {
            let item = NSMenuItem(
                title: SessionIndexTable.title(of: column).text, action: #selector(toggleColumn(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = column.rawValue
            item.state = shown.contains(column) ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func toggleColumn(_ item: NSMenuItem) {
        guard let app = model?.app, let name = item.representedObject as? String,
            let column = IndexColumns.Column(rawValue: name)
        else { return }
        app.indexColumns.toggle(column)
        apply(app.indexColumns)
    }
}

/// The header of the index list. Its menu chooses the columns.
final class IndexHeaderView: NSTableHeaderView {
    override func menu(for event: NSEvent) -> NSMenu? { (tableView?.dataSource as? IndexTableSource)?.headerMenu() }
}
