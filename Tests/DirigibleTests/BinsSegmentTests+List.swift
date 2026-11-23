import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The list of the Bins segment: its rows, keys, rename field, and actions.
extension BinsSegmentTests {
    /// A menu with the key items of the list. Each item runs `AppDelegate.timeline(_:event:in:)` with the
    /// key, as a menu item of the app does. A detached `NSMenu` ignores Shift on Return (plain Return
    /// runs the Shift-Return item), so `press` picks the item with the exact modifiers, as the menu bar does.
    @MainActor final class RouteMenu: NSObject {
        let menu = NSMenu()
        var event: NSEvent?
        var route: (TimelineCommand, NSEvent?) -> Void = { _, _ in }

        init(_ commands: [TimelineCommand] = [.addMarker, .markerInfo, .renameTrack]) {
            super.init()
            let items = (TimelineCommand.markerItems + TimelineCommand.trackItems + TimelineCommand.pasteboardItems)
                .filter { commands.contains($0.command) }
            for item in items {
                let menuItem = NSMenuItem(
                    title: "\(item.command)", action: #selector(hit(_:)), keyEquivalent: String(item.key.character))
                menuItem.keyEquivalentModifierMask = NSEvent.ModifierFlags(item.modifiers)
                menuItem.target = self
                menuItem.representedObject = item.command
                menu.addItem(menuItem)
            }
        }

        @objc func hit(_ item: NSMenuItem) {
            if let command = item.representedObject as? TimelineCommand { route(command, event) }
        }

        /// A key press: the menu key first, else the first responder of the window.
        func press(_ event: NSEvent, in window: NSWindow) {
            self.event = event
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let index = menu.items.firstIndex {
                $0.keyEquivalent == event.charactersIgnoringModifiers && $0.keyEquivalentModifierMask == flags
            }
            if let index { menu.performActionForItem(at: index) } else { window.sendEvent(event) }
        }
    }

    func chord(
        _ characters: String, code: UInt16, _ flags: NSEvent.ModifierFlags, in window: NSWindow, held: Bool = false
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: held,
            keyCode: code)!
    }

    /// The window at Bins with Jingle selected, the list focused, the playhead at 300,000, the route menu,
    /// and a count of beeps, in `app` or the app of the suite.
    func focusedList(in app: AppDelegate? = nil) async throws -> (SessionWindow, Studio, NSWindow, RouteMenu, () -> Int)
    {
        let app = app ?? self.app
        let (model, studio, window) = try await open(.bins, in: app)
        app.key = model
        var beeps = 0
        model.beep = { beeps += 1 }
        await studio.perform(.seek(.frame(300_000)))
        model.selectBinItem(.session("item1"))
        let table = try #require(model.leadingPane.binsTable)
        try #require(window.makeFirstResponder(table))
        try #require(model.binsListHasFocus(in: window))
        let route = RouteMenu()
        route.route = { command, event in app.timeline(command, event: event, in: window) }
        return (model, studio, window, route, { beeps })
    }

    func starts(_ studio: Studio, _ track: TrackID) -> [Frames] {
        studio.session.track(track)?.clips.map(\.start) ?? []
    }

    func itemCell(_ model: SessionWindow, row: Int = 1) throws -> BinItemCell {
        let table = try #require(model.leadingPane.binsTable)
        return try #require(table.view(atColumn: 0, row: row, makeIfNecessary: true) as? BinItemCell)
    }

    @Test func listKeysPasteInsertRename() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, studio, window, route, beeps) = try await focusedList()
        route.press(chord("\r", code: 36, .command, in: window), in: window)
        #expect(starts(studio, "t1") == [0, 192_000, 300_000], "Command-Return did not paste at the playhead")
        route.press(chord("\r", code: 36, .shift, in: window), in: window)
        #expect(starts(studio, "t1") == [0, 192_000, 300_000, 396_000], "Shift-Return did not insert")
        #expect(starts(studio, "t2") == [48_000], "an insert at 300,000 moved an earlier clip")
        route.press(chord("\r", code: 36, [], in: window), in: window)
        #expect(model.leadingPane.binRename == .item("item1"), "Return did not open the rename")
        #expect(beeps() == 0 && model.renamingTrack == nil, "no beep and no track rename")
        await model.close()
    }

    @Test func listKeysAddNoMarker() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, studio, window, route, _) = try await focusedList()
        route.press(chord("\r", code: 36, .command, in: window), in: window)
        #expect(studio.session.markers.isEmpty, "Command-Return in the list added a marker")

        // The near input: with the focus in the lanes, Command-Return adds a marker.
        try #require(window.makeFirstResponder(model.timelineView?.lanes))
        route.press(chord("\r", code: 36, .command, in: window), in: window)
        #expect(studio.session.markers.count == 1, "Command-Return in the lanes added no marker")
        await model.close()
    }

    @Test func listEditKeysLeaveTheTracks() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, studio, window, _, beeps) = try await focusedList()
        model.timeline.selection = .range(Marks(inPoint: 24_000, outPoint: 72_000, tracks: ["t1"]))
        model.copy(try studio.session.excerpt(of: 0..<48_000, on: ["t2"]), of: studio)
        let tracks = studio.session.tracks
        let edits: [TimelineCommand] = [.split, .cut, .copy, .paste, .insert, .removeTrack, .addChapter, .fade]
        for command in edits {
            app.timeline(command, event: chord("x", code: 7, .command, in: window), in: window)
        }
        #expect(studio.session.tracks == tracks, "a key in the list changed the tracks")
        #expect(beeps() == edits.count, "each timeline edit beeps: \(beeps())")
        app.timeline(.delete, event: chord("\u{7f}", code: 51, [], in: window), in: window)
        #expect(studio.session.tracks == tracks, "Delete in the list deleted the timeline selection")
        #expect(studio.session.bins.first?.items.isEmpty == true, "Delete did not remove the item")
        await model.close()
    }

    @Test func returnInTheRenameFieldCommits() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, studio, window, route, _) = try await focusedList()
        route.press(chord("\r", code: 36, [], in: window), in: window)
        let editor = try await renameEditor(model, window)
        editor.insertText("Theme", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        route.press(chord("\r", code: 36, [], in: window), in: window)
        #expect(studio.session.bins.first?.items.first?.name == "Theme", "Return did not keep the typed name")
        #expect(model.leadingPane.binRename == nil, "Return started a new rename")
        await model.close()
    }

    @Test func contextMenuPastesAndInserts() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, studio, _, _, _) = try await focusedList()
        let source = try #require(model.leadingPane.binsTable?.dataSource as? BinsTableSource)
        let menu = try #require(source.contextMenu(row: 1))
        #expect(menu.items.prefix(2).map(\.title) == [L10n.binsPaste.text, L10n.binsInsert.text])
        menu.performActionForItem(at: 0)
        #expect(starts(studio, "t1") == [0, 192_000, 300_000], "Paste at Playhead differs from Command-Return")
        menu.performActionForItem(at: 1)
        #expect(starts(studio, "t1") == [0, 192_000, 300_000, 396_000], "Insert at Playhead differs from Shift-Return")
        await model.close()
    }

    @Test func rowShowsNameAndLength() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, _, _) = try await open(.bins)
        let cell = try itemCell(model)
        #expect(cell.textField?.stringValue == "Jingle" && cell.length.stringValue == "0:02")
        let header = try #require(model.leadingPane.binsTable?.view(atColumn: 0, row: 0, makeIfNecessary: true))
        #expect((header as? NSTableCellView)?.textField?.stringValue == "Music", "the bin row names the bin")
        await model.close()
    }

    @Test func newItemOpensPrefilledRename() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, studio, window) = try await open(nil)
        model.timeline.selection = .range(Marks(inPoint: 48_000, outPoint: 96_000, tracks: ["t1"]))
        model.addToBin("bin1")
        #expect(model.leadingPane.shown && model.leadingPane.segment == .bins, "the add did not show the bins")
        let item = try #require(studio.session.bins.first?.items.last)
        #expect(item.name == "Host 0:01", "the prefilled name")
        #expect(model.leadingPane.binRename == .item(item.id))
        let editor = try await renameEditor(model, window)
        #expect(editor.string == "Host 0:01" && editor.selectedRange() == NSRange(location: 0, length: 9))
        await model.close()
    }

    @Test func escapeKeepsThePrefilledName() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, studio, window) = try await open(nil)
        model.timeline.selection = .range(Marks(inPoint: 48_000, outPoint: 96_000, tracks: ["t1"]))
        model.addToBin("bin1")
        let editor = try await renameEditor(model, window)
        editor.insertText("Other", replacementRange: NSRange(location: 0, length: 9))
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(model.leadingPane.binRename == nil, "Esc did not end the rename")
        #expect(studio.session.bins.first?.items.map(\.name) == ["Jingle", "Host 0:01"], "Esc changed the item")

        // An empty name after a trim keeps the name.
        model.beginBinRename(.item(try #require(studio.session.bins.first?.items.last?.id)))
        let second = try await renameEditor(model, window)
        second.insertText("  ", replacementRange: NSRange(location: 0, length: 9))
        second.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(studio.session.bins.first?.items.last?.name == "Host 0:01", "an empty name replaced the name")
        await model.close()
    }

    @Test func deleteBinItemUndoes() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, studio, window, _, _) = try await focusedList()
        let tracks = studio.session.tracks
        let item = try #require(studio.session.bins.first?.items.first)
        // The action of Edit > Delete with the Backspace key, as the app menu runs it.
        app.timeline(.delete, event: chord("\u{7f}", code: 51, [], in: window), in: window)
        #expect(studio.session.bins.first?.items.isEmpty == true, "Delete did not remove the item")
        #expect(studio.session.tracks == tracks, "Delete changed the tracks")
        try studio.undo()
        #expect(studio.session.bins.first?.items == [item], "Undo did not bring back the item with its ID and name")
        await model.close()
    }

    @Test func plainKeysReachTheMenu() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, _, window) = try await open(.bins)
        let spy = SessionIndexKeyRouteTests.PlainKeyMenu()
        let previous = NSApp.mainMenu
        NSApp.mainMenu = spy.menu
        defer { NSApp.mainMenu = previous }
        let table = try #require(model.leadingPane.binsTable)
        try #require(window.makeFirstResponder(table))
        let keys: [(String, UInt16)] = [(" ", 49), ("j", 38), ("k", 40), ("l", 37)]
        for (character, code) in keys { window.sendEvent(key(.keyDown, character, code: code, in: window)) }
        #expect(spy.hits == keys.map(\.0), "the list ran \(spy.hits)")
        #expect(table.selectedRow == -1, "J selected the row Jingle")
        await model.close()
    }

    @Test func rowIsOneAccessibilityElement() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, studio, _, _, _) = try await focusedList()
        let cell = try itemCell(model)
        #expect(cell.isAccessibilityElement() && cell.accessibilityLabel() == "Jingle, 0:02")
        #expect(cell.textField?.isAccessibilityElement() == false && !cell.length.isAccessibilityElement())
        let actions = cell.accessibilityCustomActions() ?? []
        #expect(actions.map(\.name) == [L10n.binsPaste.text, L10n.binsInsert.text, L10n.binsRename.text])
        _ = actions.first?.handler?()
        #expect(starts(studio, "t1") == [0, 192_000, 300_000], "the action Paste differs from its key")
        _ = actions.last?.handler?()
        #expect(model.leadingPane.binRename == .item("item1"), "the action Rename differs from Return")
        await model.close()
    }

    @Test func emptyBinsShowsNewBin() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, studio, _) = try await open(.bins, bins: false)
        let rows = { model.leadingPane.binsTable?.source?.rows ?? [] }
        await until("the list shows the Favorites section") { model.leadingPane.binsTable != nil }
        #expect(rows() == [.favoritesHeader, .favoritesNote(nil)], "an empty session shows a session row")
        model.newBin()
        #expect(studio.session.bins.map(\.name) == [L10n.binsNewName.format(1)])
        await until("the list shows the new bin") { rows().count == 3 }
        await model.close()
    }

    /// C32: the help tag of the row mark and the paste alert name the fault of the file.
    @Test func faultyFileItemRefusesPaste() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, studio, window, route, _) = try await focusedList()
        let tracks = studio.session.tracks
        let faults: [(MediaFault, help: L10n, text: L10n)] = [
            (.missing, .binsMissing, .errorBinMissing), (.short(1_000), .binsShort, .errorBinShort),
            (.unreadable, .binsUnreadable, .errorBinUnreadable),
        ]
        for (fault, help, text) in faults {
            studio.missingMedia = ["fa": fault]
            await until("the row has the fault \(fault)") {
                let rows = model.leadingPane.binsTable?.source?.rows ?? []
                return rows.contains { if case .item(_, let found) = $0 { found == fault } else { false } }
            }
            let mark = try itemCell(model).faultMark
            #expect(!mark.isHidden && mark.toolTip == help.text, "\(fault): \(String(describing: mark.toolTip))")
            route.press(chord("\r", code: 36, .command, in: window), in: window)
            #expect(studio.session.tracks == tracks, "a paste of a file with \(fault) added a clip")
            #expect(model.alert == .binFileFault("fa.wav", fault), "\(String(describing: model.alert))")
            #expect(model.alert?.text == text.format("fa.wav"), "\(fault)")
            model.alert = nil
        }
        await model.close()
    }

    /// The field editor of the open rename field.
    func renameEditor(_ model: SessionWindow, _ window: NSWindow) async throws -> NSTextView {
        await until("the rename field takes the focus") {
            window.contentView?.layoutSubtreeIfNeeded()
            return (window.firstResponder as? NSTextView)?.delegate is BinNameField
        }
        return try #require(window.firstResponder as? NSTextView)
    }
}
