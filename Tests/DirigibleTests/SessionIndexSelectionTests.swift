import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Several selected rows in the index list. The rows of the fixture are a (0), h1, m1, b, c, and m2 (5).
@Suite(.serialized) @MainActor struct SessionIndexSelectionTests {
    let windows: SessionIndexWindowTests

    init() throws { windows = try SessionIndexWindowTests() }

    /// The window with the list focused, the app route, and a counter of beeps.
    func list() async throws -> (SessionWindow, Studio, NSWindow, NSTableView, () -> Int) {
        let (model, studio, window, table) = try await windows.openRows()
        windows.app.key = model
        var beeps = 0
        model.beep = { beeps += 1 }
        return (model, studio, window, table, { beeps })
    }

    func chord(_ characters: String, code: UInt16, _ flags: NSEvent.ModifierFlags, in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
            keyCode: code)!
    }

    func selectAll(in window: NSWindow) {
        windows.app.timeline(.selectAll, event: chord("a", code: 0, .command, in: window), in: window)
    }

    /// A lane click on `first`, then a lane Command-click on `second`: the rows {first, second}, the anchor `second`.
    func laneSelect(_ model: SessionWindow, _ studio: Studio, _ first: ClipID, _ second: ClipID) {
        model.timeline.selection = .clips(ClipSet(first))
        model.timeline.selection = model.timeline.selection.toggling(second, in: studio.session)
    }

    @Test func shiftClickSelectsARange() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, studio, window, table, beeps) = try await list()
        try windows.click(row: 1, table, in: window)
        await model.settleTransport()
        let head = studio.playhead
        try windows.click(row: 3, table, in: window, flags: .shift)
        await model.settleTransport()
        #expect(model.timeline.selectedRows == [.marker("h1"), .marker("m1"), .clip("b")])
        #expect(table.selectedRowIndexes == [1, 2, 3] && model.timeline.anchorRow == .marker("h1"))
        #expect(model.timeline.selection == .clips(ClipSet("b")), "the clip row is the lane selection")
        #expect(studio.playhead == head && beeps() == 0, "Shift-click does not seek")
        try windows.click(row: 0, table, in: window, flags: .shift)
        #expect(model.timeline.selectedRows == [.clip("a"), .marker("h1")], "the range grows back from the anchor")
        await model.close()
    }

    @Test func commandClickTogglesARow() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, studio, window, table, beeps) = try await list()
        try windows.click(row: 0, table, in: window)
        await model.settleTransport()
        let head = studio.playhead
        try windows.click(row: 4, table, in: window, flags: .command)
        #expect(model.timeline.selectedRows == [.clip("a"), .clip("c")] && model.timeline.anchorRow == .clip("c"))
        #expect(table.selectedRowIndexes == [0, 4])
        try windows.click(row: 0, table, in: window, flags: .command)
        #expect(model.timeline.selectedRows == [.clip("c")] && table.selectedRowIndexes == [4])
        await model.settleTransport()
        #expect(studio.playhead == head && beeps() == 0, "Command-click does not seek")
        await model.close()
    }

    @Test func commandClickOnTheLastClipRowClearsTheLanes() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, _, window, table, _) = try await list()
        try windows.click(row: 0, table, in: window)
        try #require(model.timeline.selection == .clips(ClipSet("a")))
        try windows.click(row: 2, table, in: window, flags: .command)
        #expect(model.timeline.selection == .clips(ClipSet("a")) && model.timeline.marker == "m1")
        try windows.click(row: 0, table, in: window, flags: .command)
        #expect(model.timeline.selectedRows == [.marker("m1")] && model.timeline.selection == .none)
        await model.close()
    }

    @Test func commandClickOnTheMarkerRowClearsTheCurrentMarker() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, studio, window, table, beeps) = try await list()
        try windows.click(row: 2, table, in: window)
        try windows.click(row: 0, table, in: window, flags: .command)
        try #require(model.timeline.marker == "m1", "the rows still hold m1")
        try windows.click(row: 2, table, in: window, flags: .command)
        #expect(model.timeline.selectedRows == [.clip("a")] && model.timeline.marker == nil)
        try #require(window.makeFirstResponder(model.timelineView?.lanes))
        windows.app.timeline(.deleteMarker, event: chord("\u{7f}", code: 51, .command, in: window), in: window)
        #expect(beeps() == 1 && studio.session.markers["m1"] != nil, "Delete Marker keeps m1")
        await model.close()
    }

    @Test func commandASelectsOnlyTheShownRows() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, studio, window, table, beeps) = try await list()
        try windows.click(row: 2, table, in: window)
        await model.settleTransport()
        let head = studio.playhead
        func shows(_ n: Int, _ picks: Set<SessionIndex.Pick>, _ message: Comment) async throws {
            let source = try #require(table.dataSource as? IndexTableSource)
            await until("the list shows \(n) rows") { Set(source.rows.map(\.id)) == picks }
            try #require(window.makeFirstResponder(table))
            selectAll(in: window)
            #expect(model.timeline.selectedRows == picks, message)
            #expect(table.selectedRowIndexes == IndexSet(integersIn: 0..<n), message)
        }
        model.leadingPane.search = "take"
        try await shows(2, [.clip("a"), .clip("c")], "the search take gives a and c")
        model.leadingPane.search = ""
        model.leadingPane.kind = .marker
        try await shows(2, [.marker("m1"), .marker("m2")], "the filter Markers gives m1 and m2")
        model.leadingPane.kind = nil
        try await shows(6, Set(SessionIndexWindowTests.order), "no filter gives the 6 rows")
        #expect(model.timeline.selection == .clips(ClipSet(["a", "b", "c"])!) && model.timeline.marker == "m1")
        await model.settleTransport()
        #expect(studio.playhead == head && beeps() == 0, "Command-A does not seek")
        await model.close()
    }

    @Test func aFilterChangeDropsTheHiddenRows() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, _, window, table, _) = try await list()
        try windows.click(row: 2, table, in: window)
        selectAll(in: window)
        try #require(model.timeline.selectedRows.count == 6 && model.timeline.marker == "m1")
        model.leadingPane.search = "take2"
        await until("the drop runs") { model.timeline.selectedRows == [.clip("c")] }
        #expect(table.selectedRowIndexes == [0] && model.timeline.selection == .clips(ClipSet("c")))
        #expect(model.timeline.marker == nil, "the hidden row of the current marker clears it")
        await model.close()
    }

    @Test func aFilterThatHidesNoSelectedRowWritesNothing() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, _, window, table, _) = try await list()
        model.leadingPane.search = "take"
        await until("the list shows 2 rows") { table.numberOfRows == 2 }
        selectAll(in: window)
        let (revision, pushes, bodies) = (
            model.timeline.rowsRevision, model.leadingPane.pushes, model.leadingPane.bodies
        )
        model.leadingPane.search = "tak"
        await until("the pane draws the key") { model.leadingPane.bodies > bodies }
        for _ in 0..<5 { await Task.yield() }
        #expect(model.timeline.rowsRevision == revision && model.leadingPane.pushes == pushes, "no push")
        await model.close()
    }

    @Test func aSecondDeselectAllKeepsTheCurrentMarker() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, _, window, table, _) = try await list()
        try windows.click(row: 2, table, in: window)
        windows.app.timeline(.deselectAll, event: chord("a", code: 0, [.command, .shift], in: window), in: window)
        try #require(model.timeline.selectedRows.isEmpty)
        let (revision, pushes) = (model.timeline.rowsRevision, model.leadingPane.pushes)
        windows.app.timeline(.deselectAll, event: nil, in: window)
        #expect(model.timeline.marker == "m1", "the second Deselect All writes nothing")
        #expect(model.timeline.rowsRevision == revision && model.leadingPane.pushes == pushes)
        await model.close()
    }

    @Test func shiftArrowsExtendWithNoSeek() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, studio, window, table, beeps) = try await list()
        try windows.click(row: 0, table, in: window)
        await model.settleTransport()
        let head = studio.playhead
        try windows.arrow(true, shift: true, in: window)
        #expect(model.timeline.selectedRows == [.clip("a"), .marker("h1")] && table.selectedRowIndexes == [0, 1])
        await model.settleTransport()
        #expect(studio.playhead == head && beeps() == 0, "Shift-Down Arrow does not seek")
        try windows.arrow(false, shift: true, in: window)
        #expect(model.timeline.selectedRows == [.clip("a")], "Shift-Up Arrow takes the end back")
        try windows.arrow(false, shift: true, in: window)
        #expect(model.timeline.selectedRows == [.clip("a")], "the first row is the least end")

        // The moved end is the row of the last Shift-click, and the anchor c is the start.
        laneSelect(model, studio, "a", "c")
        try windows.click(row: 3, table, in: window, flags: .shift)
        try #require(model.timeline.selectedRows == [.clip("b"), .clip("c")])
        try windows.arrow(true, shift: true, in: window)
        #expect(model.timeline.selectedRows == [.clip("c")], "the end goes from b to c, not from a stale c to m2")
        try windows.click(row: 5, table, in: window, flags: .shift)
        try windows.arrow(true, shift: true, in: window)
        #expect(model.timeline.selectedRows == [.clip("c"), .marker("m2")], "m2 is the last row")
        await model.close()
    }

    @Test func aShiftClickExtendsFromTheLaneAnchor() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, studio, window, table, _) = try await list()
        laneSelect(model, studio, "a", "c")
        try #require(model.timeline.anchorRow == .clip("c"))
        try windows.click(row: 5, table, in: window, flags: .shift)
        #expect(model.timeline.selectedRows == [.clip("c"), .marker("m2")] && model.timeline.anchorRow == .clip("c"))
        laneSelect(model, studio, "a", "c")
        try windows.arrow(true, shift: true, in: window)
        #expect(model.timeline.selectedRows == [.clip("c"), .marker("m2")], "Shift-Down Arrow, not rows a and h1")
        await model.close()
    }

    @Test func aSelectionOfSeveralRowsThatAppKitMakesSeeksNowhere() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, studio, _, table, _) = try await list()
        await model.settleTransport()
        let head = studio.playhead
        table.selectRowIndexes([1, 2, 3], byExtendingSelection: false)
        await model.settleTransport()
        #expect(model.timeline.selectedRows == [.marker("h1"), .marker("m1"), .clip("b")])
        #expect(model.timeline.selection == .clips(ClipSet("b")) && studio.playhead == head)
        await model.close()
    }

    @Test func shiftDownScrollsToTheMovedEnd() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, studio, window, table, _) = try await list()
        try windows.addMarkers(to: studio)
        await until("the list shows 46 rows") { table.numberOfRows == 46 }
        try windows.click(row: 0, table, in: window)
        let visible = { table.enclosingScrollView?.contentView.bounds ?? .zero }
        try #require(visible().height < table.rect(ofRow: 45).maxY, "the list scrolls")
        var end = 0
        while visible().intersects(table.rect(ofRow: 0)), end < 45 {
            try windows.arrow(true, shift: true, in: window)
            end += 1
        }
        #expect(visible().intersects(table.rect(ofRow: end)), "the moved end is in view")
        #expect(!visible().intersects(table.rect(ofRow: 0)), "the list does not scroll back to the anchor")
        #expect(model.timeline.selectedRows.count == end + 1)
        await model.close()
    }
}
