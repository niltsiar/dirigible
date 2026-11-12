import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The keys of the session index list reach the lanes and the menu items, never the Silences list. The window and the
/// keys come from `SilencesInspectorTests`, whose list is the near input.
@Suite(.serialized) @MainActor struct SessionIndexKeyRouteTests {
    let base: SilencesInspectorTests
    let windows: SessionIndexWindowTests

    init() throws {
        base = try SilencesInspectorTests()
        windows = try SessionIndexWindowTests()
    }

    @Test func returnAndDeleteInTheIndexLeaveTheSilences() async throws {
        defer { base.defaults.removePersistentDomain(forName: base.suite) }
        let (model, studio, window, silenceTable) = try await base.focusedList("index-keys")
        let app = base.app
        let actions = { base.rows(model).map(\.action) }

        // The near input: with the focus in the Silences table, Delete sets the selected row to Skip.
        model.selectSilences([0])
        app.timeline(.delete, event: key(.keyDown, "\u{7f}", code: 51, in: window), in: window)
        try #require(
            actions() == [.skip, .shorten], "Delete in the Silences list did not reach the rows: \(actions())")
        model.setSilenceAction(.shorten, rows: [0, 1])
        try #require(model.canApplySilences && !studio.canUndo, "the plan is ready to apply")

        model.toggleIndex()
        await until("the index table shows") { model.leadingPane.table != nil }
        let index = try #require(model.leadingPane.table)
        try #require(index !== silenceTable, "the index has its own table")
        try #require(window.makeFirstResponder(index), "the index takes the focus")

        app.timeline(.renameTrack, event: base.returnKey(in: window), in: window)
        #expect(!studio.canUndo && model.silences.note == nil, "Return in the index applied the plan")
        model.selectSilences([0])
        app.timeline(.delete, event: key(.keyDown, "\u{7f}", code: 51, in: window), in: window)
        #expect(actions() == [.shorten, .shorten], "Delete in the index set a silence to Skip: \(actions())")
        #expect(!studio.canUndo && model.canApplySilences, "the silence actions kept")
        await model.close()
    }

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

    func pressReturn(shift: Bool = false, in window: NSWindow) -> NSEvent {
        chord("\r", code: 36, shift ? .shift : [], in: window)
    }

    @Test func returnOnAClipRowShowsTheClipTab() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, _, window, table, beeps) = try await list()
        try windows.click(row: 0, table, in: window)
        windows.app.timeline(.renameTrack, event: pressReturn(in: window), in: window)
        #expect(model.showsInspector && model.inspectorTab == .clip, "Return shows the Clip tab")
        #expect(beeps() == 0 && model.renamingTrack == nil, "no beep and no track rename")

        // The near input: with the focus in the lanes, Return renames the selected track.
        try #require(window.makeFirstResponder(model.timelineView?.lanes))
        model.clickHeader("t1", flags: [])
        windows.app.timeline(.renameTrack, event: pressReturn(in: window), in: window)
        #expect(model.renamingTrack == "t1", "Return in the lanes renames the track")
        await model.close()
    }

    @Test func shiftReturnOnAMarkerRowShowsMarkerInfo() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, _, window, table, beeps) = try await list()
        try windows.click(row: 5, table, in: window)
        try windows.click(row: 2, table, in: window)
        windows.app.timeline(.markerInfo, event: pressReturn(shift: true, in: window), in: window)
        #expect(model.showsInspector && model.inspectorTab == .marker && beeps() == 0)
        #expect(model.timeline.marker == "m1", "the Marker tab shows the marker of the row")
        await model.close()
    }

    @Test func shiftReturnOnAClipRowBeeps() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, _, window, table, beeps) = try await list()
        try windows.click(row: 5, table, in: window)
        try windows.click(row: 4, table, in: window)
        windows.app.timeline(.markerInfo, event: pressReturn(shift: true, in: window), in: window)
        #expect(beeps() == 1, "Shift-Return on a clip row beeps")
        #expect(!model.showsInspector, "no Marker tab for the marker m2 that no row shows")
        await model.close()
    }

    @Test func returnOnAMarkerRowBeepsUntilTheRename() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, studio, window, table, beeps) = try await list()
        try windows.click(row: 2, table, in: window)
        windows.app.timeline(.renameTrack, event: pressReturn(in: window), in: window)
        #expect(beeps() == 1 && model.renamingTrack == nil && !studio.canUndo, "Return on a marker row beeps")
        await model.close()
    }

    @Test func aClickOnRenameTrackRenamesTheTrack() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, _, window, table, beeps) = try await list()
        model.clickHeader("t1", flags: [])
        try windows.click(row: 2, table, in: window)
        try #require(window.makeFirstResponder(table))
        windows.app.timeline(.renameTrack, event: nil, in: window)
        #expect(model.renamingTrack == "t1" && beeps() == 0, "a menu click runs the item as in the lanes")
        await model.close()
    }

    @Test func deleteBeepsInTheListInL1() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, studio, window, table, beeps) = try await list()
        let selection = model.timeline.selection
        try windows.click(row: 2, table, in: window)
        windows.app.timeline(.delete, event: key(.keyDown, "\u{7f}", code: 51, in: window), in: window)
        windows.app.timeline(.selectAll, event: chord("a", code: 0, .command, in: window), in: window)
        #expect(beeps() == 2, "Delete and Command-A beep")
        #expect(table.numberOfRows == 6 && studio.session.markers["m1"] != nil && !studio.canUndo)
        #expect(model.timeline.selectedRows == [.marker("m1")] && model.timeline.selection == selection)
        await model.close()
    }

    @Test func shiftKeysBeepInTheListInL1() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, studio, window, table, beeps) = try await list()
        try windows.click(row: 2, table, in: window)
        await model.settleTransport()
        let head = studio.playhead
        try windows.arrow(true, shift: true, in: window)
        try windows.arrow(false, shift: true, in: window)
        try windows.click(row: 3, table, in: window, flags: .shift)
        try windows.click(row: 3, table, in: window, flags: .command)
        await model.settleTransport()
        #expect(beeps() == 4, "Shift-Up, Shift-Down, Shift-click, and Command-click beep")
        #expect(model.timeline.selectedRows == [.marker("m1")] && table.selectedRow == 2, "the row stays")
        #expect(studio.playhead == head, "the playhead stays")
        await model.close()
    }

    @Test func deselectAllInTheListEmptiesTheRowsOnly() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, _, window, table, beeps) = try await list()
        let marks = Marks(inPoint: 48_000, outPoint: 144_000)
        model.timeline.selection = .range(marks)
        for event in [chord("a", code: 0, [.command, .shift], in: window), nil] {
            try windows.click(row: 2, table, in: window)
            try #require(model.timeline.selectedRows == [.marker("m1")])
            windows.app.timeline(.deselectAll, event: event, in: window)
            #expect(model.timeline.selectedRows.isEmpty && model.timeline.anchorRow == nil, "no row")
            #expect(model.timeline.selection == .range(marks) && model.timeline.marker == "m1", "lanes keep")
            #expect(table.selectedRow == -1 && beeps() == 0)
        }
        await model.close()
    }

    @Test func shiftDeleteAndCutBeepInTheList() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, studio, window, table, beeps) = try await list()
        let marks = Marks(inPoint: 48_000, outPoint: 144_000)
        model.timeline.selection = .range(marks)
        try windows.click(row: 2, table, in: window)
        let before = studio.session
        windows.app.timeline(.deleteCloseGap, event: chord("\u{7f}", code: 51, .shift, in: window), in: window)
        windows.app.timeline(.cut, event: chord("x", code: 7, .command, in: window), in: window)
        windows.app.timeline(.cut, event: nil, in: window)
        #expect(beeps() == 3, "three beeps")
        #expect(studio.session == before && !studio.canUndo && model.timeline.selection == .range(marks))
        await model.close()
    }
}
