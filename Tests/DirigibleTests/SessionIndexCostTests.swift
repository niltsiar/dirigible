import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp

/// The work that the index list must not do again for each row it shows.
@Suite(.serialized) @MainActor struct SessionIndexCostTests {
    /// The name cells of one kind show one glyph image, also after a reload. A new image for each
    /// cell looks up its symbol and draws it again, for each row in view of each reload.
    @Test func theNameCellsOfOneKindShareOneGlyphImage() async throws {
        let windows = try SessionIndexWindowTests()
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, _, window, table) = try await windows.openRows()
        let source = try #require(table.dataSource as? IndexTableSource)
        func glyphs() -> [(kind: SessionIndex.Kind, image: NSImage)] {
            (0..<table.numberOfRows).compactMap { n in
                let cell = table.view(atColumn: 0, row: n, makeIfNecessary: false) as? NSTableCellView
                return cell?.imageView?.image.map { (source.rows[n].kind, $0) }
            }
        }
        let shown = glyphs()
        try #require(shown.count == 6, "each of the six rows shows a glyph")
        for kind in SessionIndex.Kind.allCases {
            let images = shown.filter { $0.kind == kind }.map(\.image)
            #expect(images.allSatisfy { $0 === images.first }, "one image for the \(kind) rows")
        }
        table.reloadData()
        window.contentView?.layoutSubtreeIfNeeded()
        let reloaded = glyphs()
        try #require(reloaded.count == 6, "the reload shows each row again")
        for (kind, image) in reloaded {
            #expect(shown.contains { $0.kind == kind && $0.image === image }, "the reload keeps the \(kind) image")
        }
        await model.close()
    }

    /// The 300 markers "Mark 0" to "Mark 299" from frame `first`, 100 frames apart. An add or a removal
    /// of all of them is a change over `SessionIndex.updateLimit`.
    static func marks(from first: Int) -> [Marker] {
        (0..<300).map {
            Marker(
                id: MarkerID("x\(first)-\($0)"), name: "Mark \($0)", position: Frames(first + $0 * 100), kind: .marker)
        }
    }

    static func add(_ marks: [Marker], to studio: Studio) throws {
        try studio.edit(ripple: false) { session throws(SessionError) in
            for mark in marks { try session.setMarker(mark) }
        }
    }

    static func remove(_ marks: [Marker], from studio: Studio) throws {
        try studio.edit(ripple: false) { session throws(SessionError) in
            for mark in marks { try session.removeMarker(mark.id) }
        }
    }

    /// The rows in view whose row view or cells do not show the row of their index: the label, the
    /// selection, the name, the glyph and its tint, and the start.
    static func stale(_ table: NSTableView) throws -> [Int] {
        let source = try #require(table.dataSource as? IndexTableSource)
        let range = table.rows(in: table.visibleRect)
        func glyph(_ kind: SessionIndex.Kind) -> Data? {
            NSImage(systemSymbolName: IndexTableSource.symbol(kind), accessibilityDescription: nil)?.tiffRepresentation
        }
        return (range.location..<NSMaxRange(range)).filter { n in
            let row = source.rows[n]
            let view = table.rowView(atRow: n, makeIfNecessary: false)
            let name = table.view(atColumn: 0, row: n, makeIfNecessary: false) as? NSTableCellView
            let start = table.view(atColumn: 1, row: n, makeIfNecessary: false) as? NSTableCellView
            return table.spokenLabel(row: n) != IndexTableSource.spoken(row, rate: 48_000)
                || view?.isSelected != table.isRowSelected(n) || name?.textField?.stringValue != row.name
                || name?.imageView?.isHidden != false || name?.imageView?.contentTintColor != .secondaryLabelColor
                || name?.imageView?.image?.tiffRepresentation != glyph(row.kind)
                || start?.textField?.stringValue != timeDisplayText(row.position, rate: 48_000, playing: false)
        }
    }

    /// A change of more rows than the update limit that drops no row view in view keeps them: they
    /// show their new rows, with no `reloadData` and no new cell view for them. A reload makes each row
    /// in view again.
    @Test func aChangeOverTheLimitKeepsTheRowViewsInView() async throws {
        let windows = try SessionIndexWindowTests()
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, studio, window, rows) = try await windows.openRows()
        // With Follow on, a display tick can scroll the list to the row of the head at any time.
        model.timeline.follows = false
        let table = try #require(rows as? IndexTableView)
        let source = try #require(table.dataSource as? IndexTableSource)
        let first = try (0..<6).map { try #require(table.rowView(atRow: $0, makeIfNecessary: false)) }
        let (reloads, cells) = (table.reloads, source.cellViews)
        let marks = Self.marks(from: 1)
        try Self.add(marks, to: studio)
        await until("the list shows 306 rows") { table.numberOfRows == 306 }
        window.contentView?.layoutSubtreeIfNeeded()
        var held: [Int: NSTableRowView] = [:]
        table.enumerateAvailableRowViews { view, n in held[n] = view }
        #expect(table.reloads == reloads, "\(table.reloads - reloads) reloadData calls")
        #expect(source.cellViews - cells == 2 * (held.count - 6), "cell views only for the \(held.count - 6) new rows")
        #expect((0..<6).allSatisfy { table.rowView(atRow: $0, makeIfNecessary: false) === first[$0] })
        #expect(try Self.stale(table) == [], "each row in view shows its own row")

        // Rows: clip a, the marks, then 5 rows from frame 48,000. The kept marks fill the rows in view.
        let kept = held.count - 6
        try #require(kept >= 0 && marks.count - kept > SessionIndex.updateLimit, "\(held.count) rows in view")
        try Self.remove(Array(marks[kept...]), from: studio)
        await until("the list shows \(held.count) rows") { table.numberOfRows == held.count }
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(table.reloads == reloads, "\(table.reloads - reloads) reloadData calls")
        #expect(source.cellViews - cells == 2 * (held.count - 6), "no cell view made for the held rows")
        #expect(held.allSatisfy { table.rowView(atRow: $0.key, makeIfNecessary: false) === $0.value })
        #expect(try Self.stale(table) == [], "each row in view shows its own row")
        await model.close()
    }

    /// A change that drops row views, again and again, keeps the views of the list at one count: a
    /// view that stays in the table adds to each display of the window. A removal of all rows and an
    /// Undo, and a removal of 300 of 306 rows and an Undo.
    @Test func aChangeThatDropsRowViewsLeavesNoViewBehind() async throws {
        let windows = try SessionIndexWindowTests()
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, studio, window, table) = try await windows.openRows()
        model.timeline.follows = false
        let marks = Self.marks(from: 1)
        try Self.add(marks, to: studio)
        await until("the list shows 306 rows") { table.numberOfRows == 306 }
        let clips = studio.session.tracks.flatMap { $0.clips.map(\.id) }
        let markers = Array(studio.session.markers.keys)
        func settle() {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        settle()
        var counts = [windows.views(NSView.self, in: table).count]
        for cycle in 0..<3 {
            try studio.edit(ripple: false) { session throws(SessionError) in
                try session.removeClips(clips)
                for id in markers { try session.removeMarker(id) }
            }
            await until("cycle \(cycle): the list shows no row") { table.numberOfRows == 0 }
            settle()
            try studio.undo()
            await until("cycle \(cycle): the list shows 306 rows") { table.numberOfRows == 306 }
            settle()
            try Self.remove(marks, from: studio)
            await until("cycle \(cycle): the list shows 6 rows") { table.numberOfRows == 6 }
            settle()
            #expect(try Self.stale(table) == [], "cycle \(cycle): each of the 6 rows shows its own row")
            try Self.add(marks, to: studio)
            await until("cycle \(cycle): the list shows 306 rows") { table.numberOfRows == 306 }
            settle()
            counts.append(windows.views(NSView.self, in: table).count)
        }
        #expect(Set(counts).count == 1, "views of the list after each cycle: \(counts)")
        #expect(try Self.stale(table) == [], "each row in view shows its own row")
        await model.close()
    }

    /// After a change over the limit the selection shows on the row of the selected item, the list
    /// shows it, and each row in view shows its own row. A list scrolled far down that falls to 6 rows
    /// shows all 6.
    @Test func aChangeOverTheLimitShowsTheSelectionAndAValidScroll() async throws {
        let windows = try SessionIndexWindowTests()
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, studio, window, table) = try await windows.openRows()
        model.timeline.follows = false
        let marks = Self.marks(from: 1)
        try Self.add(marks, to: studio)
        await until("the list shows 306 rows") { table.numberOfRows == 306 }
        model.timeline.selectRows([.marker("m1")], anchor: .marker("m1"))
        await until("row m1 is selected") { table.selectedRow == 302 }
        window.contentView?.layoutSubtreeIfNeeded()

        try Self.remove(marks, from: studio)
        await until("the list shows 6 rows") { table.numberOfRows == 6 }
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(table.selectedRowIndexes == [2], "m1 is row 2")
        #expect(table.rows(in: table.visibleRect) == NSRange(0..<6), "all 6 rows are in view")
        #expect(try Self.stale(table) == [], "each row in view shows its own row")

        try Self.add(marks, to: studio)
        await until("the list shows 306 rows") { table.numberOfRows == 306 }
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(table.selectedRowIndexes == [302], "m1 is row 302")
        #expect(NSLocationInRange(302, table.rows(in: table.visibleRect)), "the list shows m1")
        #expect(try Self.stale(table) == [], "each row in view shows its own row")

        model.timeline.selectRows([], anchor: nil)
        await until("no row is selected") { table.selectedRow == -1 }
        table.scrollRowToVisible(150)
        window.contentView?.layoutSubtreeIfNeeded()
        try Self.remove(marks, from: studio)
        await until("the list shows 6 rows") { table.numberOfRows == 6 }
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(table.rows(in: table.visibleRect) == NSRange(0..<6), "all 6 rows are in view")
        #expect(try Self.stale(table) == [], "each row in view shows its own row")
        await model.close()
    }

    /// An open row field stays open with its text over a change over the limit: the same field when
    /// its row keeps its place, else a field on the new row of the edited marker. Nothing is saved
    /// until Return.
    @Test func aChangeOverTheLimitKeepsTheOpenRowField() async throws {
        let renames = try SessionIndexRenameTests()
        defer { renames.windows.defaults.removePersistentDomain(forName: renames.windows.suite) }
        let (model, studio, window, table, _) = try await renames.open()
        let field = try renames.start(row: 2, table, in: window)
        renames.type("Zed", in: window)
        func open(at row: Int) -> Bool {
            window.contentView?.layoutSubtreeIfNeeded()
            let fields = renames.windows.views(NSTextField.self, in: table).filter(\.isEditable)
            return fields.count == 1 && table.row(for: fields[0]) == row && fields[0].currentEditor()?.string == "Zed"
        }
        let after = Self.marks(from: 250_000)
        try Self.add(after, to: studio)
        await until("the list shows 306 rows") { table.numberOfRows == 306 }
        #expect(open(at: 2) && renames.rowField(in: table) === field, "the same field stays on row 2")

        let before = Self.marks(from: 1)
        try studio.edit(ripple: false) { session throws(SessionError) in
            for mark in after { try session.removeMarker(mark.id) }
            for mark in before { try session.setMarker(mark) }
        }
        await until("the field moves with m1 to row 302") { open(at: 302) }

        try Self.remove(before, from: studio)
        await until("the field moves with m1 to row 2") { open(at: 2) }
        #expect(renames.name("m1", in: studio) == "Breath", "nothing is saved yet")
        #expect(try Self.stale(table).filter { $0 != 2 } == [], "only the field row shows the typed name")
        renames.pressReturn(in: window)
        #expect(renames.name("m1", in: studio) == "Zed", "Return saves the typed name")
        await model.close()
    }
}
