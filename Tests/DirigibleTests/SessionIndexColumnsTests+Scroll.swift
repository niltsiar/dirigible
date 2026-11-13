import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp

/// The index list keeps its geometry right when a column shows or hides, or the pane resizes, while
/// the list is scrolled sideways.
extension SessionIndexColumnsTests {
    @MainActor struct Geometry {
        let table: NSTableView
        let clip: NSClipView

        var originX: CGFloat { clip.bounds.origin.x }
        var clipWidth: CGFloat { clip.bounds.width }
        var shown: [NSTableColumn] { table.tableColumns.filter { !$0.isHidden } }
        /// The width that the shown columns take with their spacing.
        var columnsWidth: CGFloat { shown.reduce(0) { $0 + $1.width + table.intercellSpacing.width } }
        var nameWidth: CGFloat { table.tableColumns[0].width }
        /// The room that Name gets: the free width, and at least its minimum.
        var nameRoom: CGFloat {
            max(table.tableColumns[0].minWidth, clipWidth - (columnsWidth - nameWidth))
        }
        var maxOriginX: CGFloat { max(0, table.frame.width - clipWidth) }
        var nameInView: Bool { table.visibleRect.intersects(table.rect(ofColumn: 0)) }
        var firstNameCellInView: Bool {
            guard let cell = table.view(atColumn: 0, row: 0, makeIfNecessary: true) else { return false }
            return table.visibleRect.intersects(cell.convert(cell.bounds, to: table))
        }

        var text: String {
            "origin \(originX) of 0...\(maxOriginX), table \(table.frame.width) pt, clip \(clipWidth) pt, "
                + "columns \(columnsWidth) pt, name \(nameWidth) pt (room \(nameRoom)), "
                + "Name in view \(nameInView), first cell in view \(firstNameCellInView)"
        }
    }

    func settle(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    func scrollSideways(_ g: Geometry, to x: CGFloat, in window: NSWindow) throws {
        let scroll = try #require(g.table.enclosingScrollView)
        g.clip.scroll(to: NSPoint(x: x, y: 0))
        scroll.reflectScrolledClipView(g.clip)
        settle(window)
    }

    func toggle(_ item: Int, of table: NSTableView, in window: NSWindow) throws {
        try headerMenu(of: table, in: window).performActionForItem(at: item)
        settle(window)
    }

    func geometry(of model: SessionWindow) throws -> Geometry {
        let table = try #require(model.leadingPane.table)
        return Geometry(table: table, clip: try #require(table.enclosingScrollView?.contentView))
    }

    /// The state that must hold after any change: the clip view inside the table, the table as wide as
    /// the pane or its columns, Name with the free width, and Name in view when the columns fit.
    func expectSound(_ g: Geometry, _ step: String) {
        #expect(g.originX >= 0 && g.originX <= g.maxOriginX, "\(step): a valid origin, \(g.text)")
        #expect(g.table.frame.width == max(g.clipWidth, g.columnsWidth), "\(step): the table width, \(g.text)")
        #expect(abs(g.nameWidth - g.nameRoom) < 0.5, "\(step): Name fills the free width, \(g.text)")
        if g.columnsWidth <= g.clipWidth {
            #expect(g.originX == 0 && g.nameInView && g.firstNameCellInView, "\(step): the columns fit, \(g.text)")
        }
    }

    /// At 240 pt, Name (60 pt), Start, and Track do not fit: the list scrolls sideways.
    @Test func hidingTheLastExtraColumnWhileScrolledBringsNameBack() async throws {
        let windows = try SessionIndexWindowTests()
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, _, window) = try await windows.open()
        let g = try geometry(of: model)
        await until("the table shows its rows") { g.table.numberOfRows == 6 }
        expectSound(g, "default columns")
        try toggle(0, of: g.table, in: window)
        expectSound(g, "Track shown")
        #expect(g.maxOriginX > 0, "Track overflows the pane, \(g.text)")
        try scrollSideways(g, to: g.maxOriginX, in: window)
        expectSound(g, "scrolled to the end")
        try toggle(0, of: g.table, in: window)
        expectSound(g, "Track hidden")
        #expect(g.nameInView && g.firstNameCellInView, "Name shows, \(g.text)")
        await model.close()
    }

    @Test func aShowAHideOfTwoColumnsAndAResizeWhileScrolledKeepTheGeometry() async throws {
        let windows = try SessionIndexWindowTests()
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, _, window) = try await windows.open()
        let g = try geometry(of: model)
        await until("the table shows its rows") { g.table.numberOfRows == 6 }
        try toggle(0, of: g.table, in: window)
        try scrollSideways(g, to: g.maxOriginX, in: window)
        try toggle(1, of: g.table, in: window)
        expectSound(g, "Duration shown while scrolled")
        try scrollSideways(g, to: g.maxOriginX, in: window)
        #expect(g.originX == g.maxOriginX && !g.nameInView, "the list scrolls to the end, \(g.text)")
        await windows.paneSize(window, to: 1_000)
        model.leadingPane.width = IndexWidth(300)
        await until("the pane takes 300 pt") {
            settle(window)
            return g.clipWidth > 280
        }
        expectSound(g, "pane resized while scrolled")
        try scrollSideways(g, to: g.maxOriginX, in: window)
        try toggle(0, of: g.table, in: window)
        try toggle(1, of: g.table, in: window)
        expectSound(g, "two columns hidden in a row")
        #expect(g.originX == 0 && g.maxOriginX == 0, "nothing to scroll, \(g.text)")
        await model.close()
    }
}
