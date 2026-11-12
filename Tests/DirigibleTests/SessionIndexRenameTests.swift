import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Rename in the row of the session index list. The fixture is that of `SessionIndexWindowTests`: the rows are
/// a (0), h1 "Intro" (1), m1 "Breath" (2), b (3), c (4), and m2 "Cut here" (5).
@Suite(.serialized) @MainActor struct SessionIndexRenameTests {
    let windows: SessionIndexWindowTests

    init() throws { windows = try SessionIndexWindowTests() }

    func open(routed: Bool = false) async throws -> (SessionWindow, Studio, NSWindow, IndexTableView, () -> Int) {
        let (model, studio, window, _) = try await windows.openRows(routed: routed)
        windows.app.key = model
        var beeps = 0
        model.beep = { beeps += 1 }
        return (model, studio, window, try #require(model.leadingPane.table), { beeps })
    }

    func event(_ characters: String, code: UInt16, _ flags: NSEvent.ModifierFlags = [], in window: NSWindow) -> NSEvent
    {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
            keyCode: code)!
    }

    /// Return by the app route, as the menu key equivalent of Track > Rename Track sends it.
    func pressReturn(in window: NSWindow) {
        windows.app.timeline(.renameTrack, event: event("\r", code: 36, in: window), in: window)
    }

    func pressF2(in window: NSWindow) {
        window.sendEvent(event("\u{F705}", code: 120, .function, in: window))
    }

    func pressTab(shift: Bool = false, in window: NSWindow) {
        window.sendEvent(event(shift ? "\u{19}" : "\t", code: 48, shift ? .shift : [], in: window))
    }

    func pressEscape(in window: NSWindow) { window.sendEvent(event("\u{1B}", code: 53, in: window)) }

    /// Each character as a key press on the first responder.
    func type(_ text: String, in window: NSWindow) {
        for character in text {
            window.sendEvent(event(String(character), code: character == " " ? 49 : 0, in: window))
        }
    }

    func rowField(in table: NSTableView) -> NSTextField? {
        windows.views(NSTextField.self, in: table).first(where: \.isEditable)
    }

    func name(_ id: MarkerID, in studio: Studio) -> String? { studio.session.markers[id]?.name }

    /// A click on `row`, then Return: the row field opens.
    func start(row: Int, _ table: NSTableView, in window: NSWindow) throws -> NSTextField {
        try windows.click(row: row, table, in: window)
        pressReturn(in: window)
        return try #require(rowField(in: table), "Return on row \(row) opened no field")
    }

    @Test func returnOnAMarkerRowStartsTheRename() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, studio, window, table, beeps) = try await open()
        let field = try start(row: 2, table, in: window)
        let editor = try #require(window.firstResponder as? NSTextView, "the field edits")
        #expect(editor.delegate === field && field.stringValue == "Breath", "the field shows the name")
        #expect(editor.selectedRange == NSRange(location: 0, length: 6), "the whole name is selected")
        #expect(table.row(for: field) == 2, "the field is over row m1")
        #expect(beeps() == 0 && !studio.canUndo && model.renamingTrack == nil)
        await model.close()
    }

    @Test func aRenameIsOneUndoStep() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, studio, window, table, _) = try await open()
        _ = try start(row: 2, table, in: window)
        type("Breath 2", in: window)
        pressReturn(in: window)
        #expect(name("m1", in: studio) == "Breath 2", "Return commits")
        #expect(rowField(in: table) == nil && window.firstResponder === table, "Return ends the field")
        try studio.undo()
        #expect(name("m1", in: studio) == "Breath" && !studio.canUndo, "one Undo gives the old name")
        await model.close()
    }

    @Test func tabMovesToTheNextMarkerName() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, studio, window, table, _) = try await open()
        var field = try start(row: 1, table, in: window)
        type("Intro 2", in: window)
        pressTab(in: window)
        #expect(name("h1", in: studio) == "Intro 2", "Tab commits")
        field = try #require(rowField(in: table), "Tab opens the next field")
        #expect(table.row(for: field) == 2 && field.stringValue == "Breath", "the next name is m1")
        pressTab(in: window)
        field = try #require(rowField(in: table))
        #expect(table.row(for: field) == 5, "Tab skips the clip rows b and c")
        pressTab(in: window)
        #expect(rowField(in: table) == nil, "at the last marker row, Tab ends")
        #expect(name("m2", in: studio) == "Cut here" && studio.canUndo, "an unchanged name adds no edit")

        field = try start(row: 2, table, in: window)
        pressTab(shift: true, in: window)
        field = try #require(rowField(in: table))
        #expect(table.row(for: field) == 1, "Shift-Tab opens the previous name")
        pressTab(shift: true, in: window)
        #expect(rowField(in: table) == nil, "at the first marker row, Shift-Tab ends")
        await model.close()
    }

    @Test func escKeepsTheName() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, studio, window, table, _) = try await open()
        _ = try start(row: 2, table, in: window)
        type("Zed", in: window)
        pressEscape(in: window)
        #expect(rowField(in: table) == nil && window.firstResponder === table, "Esc ends the field")
        #expect(name("m1", in: studio) == "Breath" && !studio.canUndo, "no commit and no undo entry")
        await model.close()
    }

    @Test func spaceTypesDuringPlay() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, studio, window, table, _) = try await open()
        await studio.perform(.seek(.start))
        await studio.perform(.playStop)
        try #require(studio.playback != .stopped, "the play runs")
        _ = try start(row: 2, table, in: window)
        type("a", in: window)
        windows.app.transport(.playStop, event: event(" ", code: 49, in: window), in: window)
        #expect((window.firstResponder as? NSTextView)?.string == "a ", "Space types")
        #expect(studio.playback != .stopped, "the play goes on")
        pressEscape(in: window)
        await studio.perform(.playStop)
        await model.close()
    }

    @Test func noRenameDuringATake() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, studio, window, table, beeps) = try await open(routed: true)
        studio.environment = windows.hal.environment
        await model.record()
        try #require(!studio.isIdle, "the take runs")
        try windows.click(row: 2, table, in: window)
        pressReturn(in: window)
        pressF2(in: window)
        #expect(rowField(in: table) == nil && beeps() == 0, "Return and F2 open no field and do not beep")
        await model.stop()
        await until("the take finalizes") { studio.transport == .idle }
        await model.close()
    }

    @Test func theEditedRowStaysUntilTheFieldEnds() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, studio, window, table, _) = try await open()
        model.leadingPane.search = "Breath"
        await until("the search shows m1 only") { table.numberOfRows == 1 }
        _ = try start(row: 0, table, in: window)
        type("Zed", in: window)
        model.leadingPane.search = "Cut"
        await until("the search shows m2 and the edited row") { table.numberOfRows == 2 }
        #expect(rowField(in: table) != nil, "the field stays open")
        pressReturn(in: window)
        #expect(name("m1", in: studio) == "Zed", "the name is saved")
        await until("the edited row leaves the list") { table.numberOfRows == 1 }
        #expect(model.timeline.marker == "m1", "the current marker stays m1")
        await model.close()
    }

    @Test func aGoneMarkerEndsTheField() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, studio, window, table, beeps) = try await open()
        _ = try start(row: 2, table, in: window)
        type("x", in: window)
        model.edit(ripple: false) { s throws(SessionError) in try s.removeMarker("m1") }
        await until("the field ends") { rowField(in: table) == nil }
        #expect(beeps() == 0 && studio.session.markers["m1"] == nil, "no beep and no commit")
        try studio.undo()
        #expect(name("m1", in: studio) == "Breath" && !studio.canUndo, "the one undo entry is the removal")
        await model.close()
    }

    @Test func theRenameActionOpensTheField() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, _, _, table, _) = try await open()
        let names = { (n: Int) in
            (table.rowView(atRow: n, makeIfNecessary: true)?.accessibilityCustomActions() ?? []).map(\.name)
        }
        #expect(
            names(4) == [L10n.indexActionGoTo.text, L10n.indexActionShowInfo.text, L10n.indexActionPlayFromHere.text],
            "a clip row has no Rename")
        let action = try #require(
            table.rowView(atRow: 2, makeIfNecessary: true)?.accessibilityCustomActions()?.first {
                $0.name == L10n.headerRename.text
            })
        _ = action.handler?()
        let field = try #require(rowField(in: table), "the action opened no field")
        #expect(table.row(for: field) == 2 && model.timeline.selectedRows == [.marker("m1")], "the row is selected")
        await model.close()
    }

    @Test func theContextMenuRenames() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, _, window, table, _) = try await open()
        func menu(row: Int) -> NSMenu? {
            let rect = table.rect(ofRow: row)
            let point = table.convert(NSPoint(x: rect.minX + 30, y: rect.midY), to: nil)
            let click = NSEvent.mouseEvent(
                with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            return table.menu(for: click)
        }
        #expect(menu(row: 4)?.items.map(\.title) == [L10n.indexMenuPlayFromHere.text], "a clip row has no Rename")
        let item = try #require(menu(row: 2)?.items.first, "a marker row has a menu")
        #expect(item.title == L10n.headerRename.text)
        _ = item.target?.perform(item.action, with: item)
        let field = try #require(rowField(in: table), "the menu item opened no field")
        #expect(table.row(for: field) == 2)
        await model.close()
    }

    @Test func f2StartsTheRenameOnAMarkerRowAndBeepsOnAClipRow() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, _, window, table, beeps) = try await open()
        try windows.click(row: 3, table, in: window)
        pressF2(in: window)
        #expect(rowField(in: table) == nil && beeps() == 1, "F2 on a clip row beeps")
        try windows.click(row: 5, table, in: window)
        pressF2(in: window)
        let field = try #require(rowField(in: table), "F2 on a marker row opened no field")
        #expect(table.row(for: field) == 5 && beeps() == 1)
        await model.close()
    }

    @Test func aRefusedNameBeepsAndKeepsTheField() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, studio, window, table, beeps) = try await open()
        let field = try start(row: 2, table, in: window)
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.insertText("a\u{7}b", replacementRange: editor.selectedRange)
        pressReturn(in: window)
        #expect(beeps() == 1 && rowField(in: table) === field, "a control character beeps and keeps the field")
        #expect(editor.string == "a\u{7}b" && !studio.canUndo, "the text stays and nothing is saved")
        model.commitDrafts()
        #expect(rowField(in: table) == nil && beeps() == 1, "a caller ends the field with no beep")
        #expect(name("m1", in: studio) == "Breath" && !studio.canUndo, "the old name stays")
        await model.close()
    }

    @Test func aTakeStartCommitsTheField() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, studio, window, table, _) = try await open(routed: true)
        studio.environment = windows.hal.environment
        _ = try start(row: 2, table, in: window)
        type("Breath 2", in: window)
        await model.record()
        try #require(!studio.isIdle, "the take runs")
        #expect(name("m1", in: studio) == "Breath 2" && rowField(in: table) == nil, "Command-R saves the typed name")
        await model.stop()
        await until("the take finalizes") { studio.transport == .idle }
        await model.close()
    }

    @Test func aCloseCommitsTheField() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, studio, window, table, _) = try await open()
        _ = try start(row: 2, table, in: window)
        type("Breath 2", in: window)
        await model.close()
        #expect(name("m1", in: studio) == "Breath 2", "a close saves the typed name")
    }

    @Test func oneEditGivesOneUndoEntry() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, studio, window, table, _) = try await open()
        _ = try start(row: 2, table, in: window)
        type("Breath 2", in: window)
        model.endNameEdit()
        model.commitDrafts()
        #expect(name("m1", in: studio) == "Breath 2" && rowField(in: table) == nil)
        try studio.undo()
        #expect(name("m1", in: studio) == "Breath" && !studio.canUndo, "the focus loss and the caller add one entry")

        _ = try start(row: 2, table, in: window)
        type("Breath 3", in: window)
        await model.close()
        try studio.undo()
        #expect(name("m1", in: studio) == "Breath" && !studio.canUndo, "a close adds one entry")
    }

    @Test func thePlayMarkSkipsTheEditedRow() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, _, window, table, _) = try await open()
        let lanes = try #require(model.timelineView)
        lanes.linkProxy?.view = nil
        model.leadingPane.kind = .marker
        await until("the Markers filter shows m1 and m2") { table.numberOfRows == 2 }
        _ = try start(row: 0, table, in: window)
        lanes.tick(playhead: 50_000, playback: SessionIndexPlayMarkTests.play)
        #expect(
            table.mark.row == 0 && table.mark.tint.isHidden && table.mark.line.isHidden, "no mark in the edited row")
        pressEscape(in: window)
        lanes.tick(playhead: 50_001, playback: SessionIndexPlayMarkTests.play)
        #expect(!table.mark.tint.isHidden && !table.mark.line.isHidden, "the mark returns at the field end")
        await model.close()
    }
}
