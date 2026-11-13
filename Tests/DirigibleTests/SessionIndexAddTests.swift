import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Add and the time field of a row of the session index list. The fixture is that of
/// `SessionIndexRenameTests`: the rows are a, h1 "Intro", m1 "Breath" (48,000), b, c, and m2
/// "Cut here" (240,000); the rate is 48 kHz.
@Suite(.serialized) @MainActor struct SessionIndexAddTests {
    let rename: SessionIndexRenameTests
    var windows: SessionIndexWindowTests { rename.windows }

    init() throws { rename = try SessionIndexRenameTests() }

    static let fixture: Set<MarkerID> = ["m1", "h1", "m2"]

    /// The marker that the test added: not one of the three of the fixture.
    func added(in studio: Studio) -> Marker? { studio.session.markers.values.first { !Self.fixture.contains($0.id) } }

    func position(_ id: MarkerID, in studio: Studio) -> Frames? { studio.session.markers[id]?.position }

    /// Command-Return, or Shift-Command-Return, through the app route as the menu key sends it.
    func pressAdd(chapter: Bool = false, repeating: Bool = false, in window: NSWindow) {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: chapter ? [.command, .shift] : [.command], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: repeating, keyCode: 36)!
        windows.app.timeline(chapter ? .addChapter : .addMarker, event: event, in: window)
    }

    func footer(below table: NSView, in window: NSWindow) -> NSPopUpButton? {
        windows.indexFooter(below: table, in: window)
    }

    func choose(_ title: L10n, in button: NSPopUpButton) throws {
        let menu = try #require(button.menu)
        let index = try #require(menu.items.firstIndex { $0.title == title.text }, "no item \(title.text)")
        menu.performActionForItem(at: index)
    }

    /// The name field of the row `id` opens, then Tab: its time field.
    func openTime(of id: MarkerID, _ table: NSTableView, in window: NSWindow) throws -> NSTextField {
        let source = try #require(table.dataSource as? IndexTableSource)
        let row = try #require(source.rows.firstIndex { $0.id == .marker(id) })
        _ = try rename.start(row: row, table, in: window)
        rename.pressTab(in: window)
        let field = try #require(rename.rowField(in: table), "Tab opens a field")
        try #require(table.column(for: field) == 1, "the field is in the Start column")
        return field
    }

    /// Replaces the text of the open field with `text`.
    func retype(_ text: String, in window: NSWindow) {
        (window.firstResponder as? NSTextView)?.selectAll(nil)
        rename.type(text, in: window)
    }

    /// Waits until the list shows marker `id` at `frame`.
    func listShows(_ id: MarkerID, at frame: Frames, _ table: NSTableView) async {
        await until("the list shows \(id) at \(frame)") {
            (table.dataSource as? IndexTableSource)?.rows.first { $0.id == .marker(id) }?.position == frame
        }
    }

    func undoSteps(_ studio: Studio) throws -> Int {
        var steps = 0
        while studio.canUndo {
            try studio.undo()
            steps += 1
        }
        return steps
    }

    @Test func thePlusMenuAddsAndRenames() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, studio, window, table, beeps) = try await rename.open()
        let button = try #require(footer(below: table, in: window), "the pane footer has a pull-down")
        let titles = (button.menu?.items ?? []).map(\.title)
        #expect(titles.contains(L10n.menuMarkersAdd.text) && titles.contains(L10n.menuMarkersAddChapter.text))

        await studio.perform(.seek(.frame(96_000)))
        try choose(.menuMarkersAdd, in: button)
        await until("the new row shows its field") { rename.rowField(in: table) != nil }
        let marker = try #require(added(in: studio), "Add Marker added a marker")
        #expect(marker.kind == .marker && marker.position == 96_000, "at the playhead")
        let field = try #require(rename.rowField(in: table))
        let source = try #require(table.dataSource as? IndexTableSource)
        #expect(table.row(for: field) == source.rows.firstIndex { $0.id == .marker(marker.id) }, "over the new row")
        #expect(model.timeline.selectedRows == [.marker(marker.id)], "the new row is selected")
        #expect(field.currentEditor()?.selectedRange.length == field.stringValue.utf16.count, "the name is selected")
        rename.type("Hello", in: window)
        rename.pressReturn(in: window)
        #expect(rename.name(marker.id, in: studio) == "Hello" && beeps() == 0)
        #expect(try undoSteps(studio) == 2, "one entry for the add and one for the name")

        await studio.perform(.seek(.frame(100_000)))
        try choose(.menuMarkersAddChapter, in: button)
        await until("the chapter shows its field") { rename.rowField(in: table) != nil }
        #expect(added(in: studio)?.kind == .chapter, "Add Chapter added a chapter")
        await model.close()
    }

    @Test func theAddKeyInTheListOpensTheField() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, studio, window, table, _) = try await rename.open()
        await studio.perform(.seek(.frame(96_000)))
        pressAdd(in: window)
        await until("the new row shows its field") { rename.rowField(in: table) != nil }
        let marker = try #require(added(in: studio))
        #expect(marker.position == 96_000 && model.timeline.selectedRows == [.marker(marker.id)])
        rename.pressEscape(in: window)
        pressAdd(repeating: true, in: window)
        #expect(studio.session.markers.count == 4, "a repeat of the key adds no marker")
        pressAdd(chapter: true, in: window)
        await until("the chapter shows its field") { rename.rowField(in: table) != nil }
        #expect(
            studio.session.markers.count == 5 && model.leadingPane.rowEdit != nil, "Shift-Command-Return adds a chapter"
        )
        await model.close()
    }

    @Test func aMenuClickAddsWithNoField() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, studio, window, table, _) = try await rename.open()
        windows.app.timeline(.addMarker, event: nil, in: window)
        let marker = try #require(added(in: studio), "the click adds m3")
        await until("the table shows the new row") { table.numberOfRows == 7 }
        #expect(rename.rowField(in: table) == nil && model.leadingPane.rowEdit == nil, "no field opens")
        #expect(model.timeline.marker == marker.id)
        await model.close()
    }

    @Test func theAddKeyInTheLanesOpensNoField() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, studio, window, table, _) = try await rename.open()
        model.focusLanes()
        pressAdd(in: window)
        try #require(added(in: studio) != nil, "the key adds a marker")
        await until("the table shows the new row") { table.numberOfRows == 7 }
        #expect(rename.rowField(in: table) == nil && model.leadingPane.rowEdit == nil, "no field opens")
        #expect(window.firstResponder !== table, "the lanes keep the focus")
        await model.close()
    }

    @Test func aNewRowShowsUnderAFilterWhileItEdits() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, studio, window, table, _) = try await rename.open()
        model.leadingPane.search = "Breath"
        await until("the search shows m1 only") { table.numberOfRows == 1 }
        pressAdd(in: window)
        await until("the new row shows its field") { rename.rowField(in: table) != nil && table.numberOfRows == 2 }
        rename.type("Zed", in: window)
        rename.pressReturn(in: window)
        await until("the new row leaves the list") { table.numberOfRows == 1 }
        #expect(added(in: studio)?.name == "Zed", "the name is saved")
        await model.close()
    }

    @Test func tabRunsFromTheNameToTheTimeToTheNextName() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, studio, window, table, _) = try await rename.open()
        _ = try rename.start(row: 2, table, in: window)
        rename.type("Breath 2", in: window)
        rename.pressTab(in: window)
        #expect(rename.name("m1", in: studio) == "Breath 2", "Tab commits the name")
        var field = try #require(rename.rowField(in: table), "Tab opens the time field of m1")
        #expect(table.row(for: field) == 2 && table.column(for: field) == 1, "the time field of m1")
        #expect(field.stringValue == "0:00:01.000", "the time shows, not the name")
        await runLoopPass()
        window.contentView?.layoutSubtreeIfNeeded()
        field = try #require(rename.rowField(in: table))
        #expect(field.stringValue == "0:00:01.000", "the update after the rename keeps the time")

        retype("0:00:06.000", in: window)
        rename.pressTab(in: window)
        #expect(position("m1", in: studio) == 288_000, "Tab commits the time")
        field = try #require(rename.rowField(in: table), "Tab opens a name field")
        #expect(table.column(for: field) == 0 && model.leadingPane.rowEdit?.marker == "m2", "the name field of m2")
        #expect(field.stringValue == "Cut here")
        await model.close()
    }

    @Test func theTimeFieldMovesTheMarker() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, studio, window, table, beeps) = try await rename.open()
        let field = try openTime(of: "m1", table, in: window)
        #expect(field.accessibilityLabel() == L10n.indexColumnStart.text, "the field is labelled Start")
        retype("0:00:02.500", in: window)
        rename.pressReturn(in: window)
        #expect(position("m1", in: studio) == 120_000 && beeps() == 0, "Return moves the marker")
        #expect(rename.rowField(in: table) == nil && model.timeline.selectedRows == [.marker("m1")])
        await until("the list sorts again") { (table.dataSource as? IndexTableSource)?.rows[3].id == .marker("m1") }
        let row = table.selectedRow
        #expect(row == 3 && table.visibleRect.intersects(table.rect(ofRow: row)), "the row stays selected and in view")
        try studio.undo()
        #expect(position("m1", in: studio) == 48_000, "one Undo moves it back")
        await model.close()
    }

    @Test func aBadTimeBeeps() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, studio, window, table, beeps) = try await rename.open()
        _ = try openTime(of: "m1", table, in: window)
        var expected = 0
        for text in ["1:7x", "-0:01", "10000:00:00", "0:00:02.5555"] {
            retype(text, in: window)
            rename.pressReturn(in: window)
            expected += 1
            #expect(beeps() == expected, "\(text) beeps")
            #expect(rename.rowField(in: table) != nil, "\(text) keeps the field open")
            #expect(position("m1", in: studio) == 48_000, "\(text) moves nothing")
        }
        rename.pressEscape(in: window)
        #expect(rename.rowField(in: table) == nil && !studio.canUndo, "Esc ends with no edit")
        #expect(position("m1", in: studio) == 48_000)
        await model.close()
    }

    @Test func tabThroughTheTimeFieldWritesNothing() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, studio, window, table, _) = try await rename.open()
        func move(_ id: MarkerID, to frame: Frames) throws {
            var marker = try #require(studio.session.markers[id])
            marker.position = frame
            try studio.edit(ripple: false) { s throws(SessionError) in try s.setMarker(marker) }
        }
        try move("m1", to: 48_123)
        await listShows("m1", at: 48_123, table)
        var field = try openTime(of: "m1", table, in: window)
        #expect(field.stringValue == "0:00:01.002", "the field shows the cut digits")
        rename.pressReturn(in: window)
        #expect(position("m1", in: studio) == 48_123 && rename.rowField(in: table) == nil, "Return writes nothing")
        field = try openTime(of: "m1", table, in: window)
        rename.pressTab(in: window)
        #expect(position("m1", in: studio) == 48_123, "Tab through the field writes nothing")
        rename.pressEscape(in: window)
        model.commitDrafts()
        #expect(try undoSteps(studio) == 1, "only the setup edit is on the undo stack")

        // An agent edit moves the marker while the field is open: the field shows the new time.
        await listShows("m1", at: 48_000, table)
        _ = try openTime(of: "m1", table, in: window)
        try move("m1", to: 48_123)
        await until("the field shows the agent time") {
            rename.rowField(in: table)?.currentEditor()?.string == "0:00:01.002"
        }
        rename.pressTab(in: window)
        #expect(position("m1", in: studio) == 48_123, "an agent move then Tab keeps the frame")
        rename.pressEscape(in: window)
        #expect(try undoSteps(studio) == 1, "the agent edit only")
        await listShows("m1", at: 48_000, table)

        // An Undo moves it while the field is open.
        try move("m1", to: 48_123)
        try move("m1", to: 60_000)
        await listShows("m1", at: 60_000, table)
        _ = try openTime(of: "m1", table, in: window)
        try studio.undo()
        await until("the field shows the undo time") {
            rename.rowField(in: table)?.currentEditor()?.string == "0:00:01.002"
        }
        rename.pressTab(in: window)
        #expect(position("m1", in: studio) == 48_123, "an Undo then Tab keeps the frame")
        rename.pressEscape(in: window)
        #expect(try undoSteps(studio) == 1, "the first edit remains: Tab added none")
        await model.close()
    }

    @Test func tabMovesBackThroughTheFields() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, _, window, table, _) = try await rename.open()
        let field = try openTime(of: "m1", table, in: window)
        rename.pressTab(shift: true, in: window)
        var open = try #require(rename.rowField(in: table), "Shift-Tab from the time opens the name of m1")
        #expect(table.row(for: open) == table.row(for: field) && table.column(for: open) == 0)
        rename.pressTab(shift: true, in: window)
        open = try #require(rename.rowField(in: table), "Shift-Tab from a name opens the time before it")
        #expect(table.row(for: open) == 1 && table.column(for: open) == 1, "the time field of h1")
        await model.close()
    }

    @Test func aTakeStartCommitsTheTimeField() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, studio, window, table, beeps) = try await rename.open(routed: true)
        studio.environment = windows.hal.environment
        _ = try openTime(of: "m1", table, in: window)
        retype("0:00:02.500", in: window)
        await model.record()
        try #require(!studio.isIdle, "the take runs")
        #expect(position("m1", in: studio) == 120_000 && rename.rowField(in: table) == nil, "Command-R saves the time")
        await model.stop()
        await until("the take finalizes") { studio.transport == .idle }

        _ = try openTime(of: "m2", table, in: window)
        retype("1:7x", in: window)
        await model.record()
        try #require(!studio.isIdle, "the second take runs")
        #expect(position("m2", in: studio) == 240_000 && rename.rowField(in: table) == nil, "a bad time ends the field")
        #expect(beeps() == 0, "with no beep")
        await model.stop()
        await until("the second take finalizes") { studio.transport == .idle }
        await model.close()
    }

    @Test func aCloseCommitsTheTimeField() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, studio, window, table, _) = try await rename.open()
        _ = try openTime(of: "m1", table, in: window)
        retype("0:00:02.500", in: window)
        await model.close()
        #expect(position("m1", in: studio) == 120_000, "a close saves the typed time")
    }

    @Test func oneTimeEditGivesOneUndoEntry() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, studio, window, table, _) = try await rename.open()
        _ = try openTime(of: "m1", table, in: window)
        retype("0:00:02.500", in: window)
        model.endNameEdit()
        model.commitDrafts()
        #expect(position("m1", in: studio) == 120_000 && rename.rowField(in: table) == nil)
        #expect(try undoSteps(studio) == 1, "a focus loss and a commit give one entry")
        #expect(position("m1", in: studio) == 48_000)
        await model.close()
    }
}
