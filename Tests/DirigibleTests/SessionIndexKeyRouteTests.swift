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

    @Test func returnShiftReturnAndShowInfoDuringPlayShowTheTabAndDoNotSeek() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, studio, window, table, beeps) = try await list()
        try windows.click(row: 4, table, in: window)
        model.transport(.playStop)
        await model.settleTransport()
        try #require(studio.playback != .stopped, "the play runs")
        model.leafCalls = []

        windows.app.timeline(.renameTrack, event: pressReturn(in: window), in: window)
        #expect(model.showsInspector && model.inspectorTab == .clip, "Return shows the Clip tab")
        try windows.arrow(true, in: window)
        windows.app.timeline(.markerInfo, event: pressReturn(shift: true, in: window), in: window)
        #expect(model.inspectorTab == .marker && model.timeline.marker == "m2", "Shift-Return shows the Marker tab")
        model.selectInspectorTab(.clip)
        try #require(table.clientAction(row: 2, .indexActionShowInfo)).perform()
        #expect(model.inspectorTab == .marker && model.timeline.marker == "m1", "Show Info shows the Marker tab")

        await model.settleTransport()
        let calls = model.leafCalls ?? []
        #expect(!calls.contains { $0.hasPrefix("seek") }, "a request for the inspector seeks: \(calls)")
        #expect(studio.playback != .stopped && beeps() == 0, "the play goes on")
        await studio.perform(.playStop)
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

    @Test func aHeldDeleteKeyInTheListRemovesOneSelection() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, studio, window, table, _) = try await list()
        let before = studio.session
        try windows.click(row: 3, table, in: window)
        windows.app.timeline(.delete, event: key(.keyDown, "\u{7f}", code: 51, in: window), in: window)
        await until("the list shows 5 rows") { table.numberOfRows == 5 }
        try #require(model.timeline.selectedRows == [.clip("c")], "the next row is the new target")
        let after = studio.session
        for _ in 0..<3 {
            windows.app.timeline(
                .delete, event: key(.keyDown, "\u{7f}", code: 51, repeat: true, in: window), in: window)
        }
        #expect(studio.session == after && table.numberOfRows == 5, "a repeat removed a row")
        #expect(model.timeline.selectedRows == [.clip("c")] && model.indexDeleted?.count == 1)
        try studio.undo()
        #expect(studio.session == before && !studio.canUndo, "one Undo gives back the one press")
        await model.close()
    }

    @Test func aHeldCommandDeleteKeyInTheListRemovesOneMarker() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, studio, window, table, _) = try await list()
        try windows.click(row: 2, table, in: window)
        try #require(model.timeline.marker == "m1")
        let held = { (repeats: Bool) in
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\u{7f}",
                charactersIgnoringModifiers: "\u{7f}", isARepeat: repeats, keyCode: 51)!
        }
        windows.app.timeline(.deleteMarker, event: held(false), in: window)
        await until("the list shows 5 rows") { table.numberOfRows == 5 }
        let after = studio.session
        for _ in 0..<3 { windows.app.timeline(.deleteMarker, event: held(true), in: window) }
        #expect(studio.session == after && table.numberOfRows == 5, "a repeat removed a marker")
        await model.close()
    }

    @Test func escapeDuringAnIndexDragRestoresTheStartWidthAndKeepsTheSelection() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, _, window, table, _) = try await list()
        let marks = Marks(inPoint: 48_000, outPoint: 144_000)
        model.timeline.selection = .range(marks)
        try windows.click(row: 2, table, in: window)
        try #require(window.makeFirstResponder(model.timelineView?.lanes))
        let start = model.leadingPane.width
        model.dragIndex(.down(x: start.points, clicks: 1))
        model.dragIndex(.drag(x: start.points + 40))
        try #require(model.leadingPane.preview != nil, "the drag shows the guide")

        window.sendEvent(try cgKey(53))
        model.dragIndex(.up)

        #expect(model.leadingPane.width == start && model.leadingPane.preview == nil, "Esc gives the start width")
        #expect(windows.defaults.object(forKey: IndexWidth.defaultsKey) == nil, "Esc saves no width")
        #expect(model.timeline.selectedRows == [.marker("m1")] && model.timeline.selection == .range(marks))
        await model.close()
    }

    /// The handle is 6 pt wide over the divider and takes the hit 2 pt on each side, as the inspector handle.
    @Test func theIndexHandleTakesTheHitOnBothSides() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, _, window, _, _) = try await list()
        let handle = try #require(windows.views(IndexHandleView.self, in: window.contentView).first)
        window.contentView?.layoutSubtreeIfNeeded()
        let frame = handle.convert(handle.bounds, to: nil)
        #expect(frame.width == 6, "\(frame)")
        for dx in [-2.0, 2] {
            let hit = window.contentView?.superview?.hitTest(NSPoint(x: frame.midX + dx, y: frame.midY))
            #expect(hit === handle, "dx \(dx): \(String(describing: hit))")
        }
        await model.close()
    }

    /// A main menu whose items are the plain keys of the transport and the Snap item, each with no modifier.
    @MainActor final class PlainKeyMenu: NSObject {
        var hits: [String] = []
        let menu = NSMenu()

        override init() {
            super.init()
            for character in [" ", "j", "k", "l", "n", "h"] {
                let item = NSMenuItem(title: character, action: #selector(hit(_:)), keyEquivalent: character)
                item.keyEquivalentModifierMask = []
                item.target = self
                menu.addItem(item)
            }
        }

        @objc func hit(_ item: NSMenuItem) { hits.append(item.keyEquivalent) }
    }

    /// A key press reaches the first responder first. With the list focused, the plain-key items of
    /// Space, J, K, L, N, and H still run, as with the lanes focused.
    @Test func plainKeysInTheListRunTheirMenuItems() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, _, window, table, _) = try await list()
        let spy = PlainKeyMenu()
        let previous = NSApp.mainMenu
        NSApp.mainMenu = spy.menu
        defer { NSApp.mainMenu = previous }
        let keys: [(String, UInt16)] = [(" ", 49), ("j", 38), ("k", 40), ("l", 37), ("n", 45), ("h", 4)]
        let press = {
            for (character, code) in keys { window.sendEvent(key(.keyDown, character, code: code, in: window)) }
        }
        try #require(window.makeFirstResponder(model.timelineView?.lanes))
        press()
        try #require(spy.hits == keys.map(\.0), "the lanes run each item: \(spy.hits)")

        spy.hits = []
        try #require(window.makeFirstResponder(table), "the list takes the focus")
        press()
        #expect(spy.hits == keys.map(\.0), "the list ran \(spy.hits)")
        #expect(table.selectedRow == -1, "a letter selected a row")
        await model.close()
    }
}
