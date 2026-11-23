import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The selected item, the rename, and the held keys of the Bins list, and the cost of the Add to Bin
/// state (code gate 1 of run `2026-10-28-favorites-bins`).
extension BinsSegmentTests {
    /// An agent edit removes the selected item: the pane drops it, so Delete and Return beep with no
    /// alert and no rename, and the list keeps the keys. A rename of an unknown row opens nothing.
    @Test func aRemovedItemLeavesNoSelection() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, studio, window, route, beeps) = try await focusedList()
        let table = try #require(model.leadingPane.binsTable)
        try studio.edit(ripple: false) { session throws(SessionError) in try session.removeItem("item1") }
        // The bin Music, then the Favorites header and "No Favorites" of a test app with no store.
        await until("the list drops the row") { table.numberOfRows == 3 }

        #expect(model.leadingPane.selectedBinItem == nil, "the pane keeps the removed item")
        app.timeline(.delete, event: chord("\u{7f}", code: 51, [], in: window), in: window)
        #expect(model.alert == nil, "Delete of a removed item: \(String(describing: model.alert))")
        route.press(chord("\r", code: 36, [], in: window), in: window)
        #expect(model.leadingPane.binRename == nil, "Return opened a rename of a removed item")
        #expect(beeps() == 2 && model.binsListHasFocus(in: window), "beeps \(beeps()), the list lost the keys")
        model.beginBinRename(.item("item1"))
        model.beginBinRename(.bin("gone"))
        #expect(model.leadingPane.binRename == nil, "a rename of an unknown row opened")
        await model.close()
    }

    /// Undo of Add to Bin while its name field is open ends the rename with no edit and clears the
    /// selection, and the list gets the keys again.
    @Test func undoOfAddToBinEndsTheRename() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, studio, window, _, _) = try await focusedList()
        let table = try #require(model.leadingPane.binsTable)
        model.timeline.selection = .range(Marks(inPoint: 48_000, outPoint: 96_000, tracks: ["t1"]))
        model.addToBin("bin1")
        let editor = try await renameEditor(model, window)
        editor.insertText("Typed", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        try studio.undo()
        await until("the list drops the new row") { table.numberOfRows == 4 }

        #expect(model.leadingPane.binRename == nil, "the rename of the removed item stays open")
        #expect(model.leadingPane.selectedBinItem == nil, "the pane keeps the removed item")
        #expect(studio.session.bins.first?.items.map(\.name) == ["Jingle"], "the end of the rename made an edit")
        #expect(model.binsListHasFocus(in: window), "the keys do not go to the list")
        await model.close()
    }

    /// Add to Bin with another item selected selects the new item, and its rename commit keeps it.
    @Test func addToBinSelectsTheNewItem() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, studio, window, route, _) = try await focusedList()
        let table = try #require(model.leadingPane.binsTable)
        try #require(table.selectedRow == 1, "control: Jingle is selected")
        model.timeline.selection = .range(Marks(inPoint: 48_000, outPoint: 96_000, tracks: ["t1"]))
        model.addToBin("bin1")
        let added = try #require(studio.session.bins.first?.items.last?.id)
        _ = try await renameEditor(model, window)

        #expect(model.leadingPane.selectedBinItem == .session(added), "the new item is not the selected item")
        #expect(table.selectedRow == 2, "the list selects row \(table.selectedRow)")
        route.press(chord("\r", code: 36, [], in: window), in: window)
        await until("the rename ends") { model.leadingPane.binRename == nil }
        #expect(
            model.leadingPane.selectedBinItem == .session(added) && table.selectedRow == 2,
            "the commit lost the selection")
        await model.close()
    }

    /// A held key gives one bin edit: the repeats of Shift-Return, Command-Return, Return, and Delete
    /// do nothing.
    @Test func aHeldKeyEditsOneItem() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, studio, window, route, _) = try await focusedList()
        route.press(chord("\r", code: 36, .shift, in: window), in: window)
        #expect(starts(studio, "t1") == [0, 192_000, 300_000], "control: Shift-Return inserts at the playhead")

        for _ in 0..<3 { route.press(chord("\r", code: 36, .shift, in: window, held: true), in: window) }
        #expect(starts(studio, "t1") == [0, 192_000, 300_000], "a held Shift-Return inserted again")
        for _ in 0..<3 { route.press(chord("\r", code: 36, .command, in: window, held: true), in: window) }
        #expect(starts(studio, "t1") == [0, 192_000, 300_000], "a held Command-Return pasted")
        route.press(chord("\r", code: 36, [], in: window, held: true), in: window)
        #expect(model.leadingPane.binRename == nil, "a held Return opened the rename")
        app.timeline(.delete, event: chord("\u{7f}", code: 51, [], in: window, held: true), in: window)
        #expect(studio.session.bins.first?.items.map(\.id) == ["item1"], "a held Delete removed the item")
        await model.close()
    }

    /// The menu state of Add to Bin builds no excerpt, so it copies the guard of
    /// `Selection.excerpt(in:)`: it is on exactly when that excerpt is not nil, also for a range whose
    /// tracks all follow, and off during a take.
    @Test func addToBinStateMatchesTheExcerpt() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, studio, _) = try await open(nil)
        let range = Selection.range(Marks(inPoint: 0, outPoint: 48_000, tracks: ["t1"]))
        let following = Selection.range(
            Marks(inPoint: 0, outPoint: 48_000, tracks: ["t1", "t2"], tracksByDefault: true))
        let states: [(String, Selection)] = [
            ("no selection", .none), ("a range", range),
            ("an empty range", .range(Marks(inPoint: 400_000, outPoint: 450_000, tracks: ["t2"]))),
            ("a range of 0 frames", .range(Marks(inPoint: 48_000, outPoint: 48_000, tracks: ["t1"]))),
            ("a clip set", .clips(ClipSet("b"))), ("a gone clip", .clips(ClipSet("gone"))),
            ("a following range", following),
        ]
        var on: [String] = []
        for (follow, cases) in [(false, states.dropLast()), (true, states.suffix(1))] {
            if follow {
                try studio.edit(ripple: false) { session throws(SessionError) in
                    try session.setFollowTrack(true, tracks: ["t1", "t2"])
                }
            }
            for (name, selection) in cases {
                model.timeline.selection = selection
                let excerpt = try? selection.excerpt(in: studio.session)
                #expect(model.canAddToBin == (excerpt != nil), "\(name): the state differs from the excerpt")
                if model.canAddToBin { on.append(name) }
            }
        }
        #expect(on == ["a range", "an empty range", "a clip set"], "control: the cases that have an excerpt")

        model.timeline.selection = range
        studio.transport = .recording(take: 1)
        #expect(!model.canAddToBin, "Add to Bin is on during a take")
        studio.transport = .idle
        await model.close()
    }

    /// A switch to Index and a window close each keep the typed name of an open rename.
    @Test func aSegmentSwitchKeepsTheTypedName() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, studio, window, route, _) = try await focusedList()
        route.press(chord("\r", code: 36, [], in: window), in: window)
        var editor = try await renameEditor(model, window)
        editor.insertText("Theme", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        model.selectSegment(.index)

        #expect(model.leadingPane.binRename == nil, "the rename stays open at Index")
        #expect(studio.session.bins.first?.items.first?.name == "Theme", "the switch lost the typed name")

        model.selectSegment(.bins)
        await until("the Bins list shows") { model.leadingPane.binsTable?.window != nil }
        model.beginBinRename(.item("item1"))
        editor = try await renameEditor(model, window)
        editor.insertText("Closed", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        await model.close()
        #expect(studio.session.bins.first?.items.first?.name == "Closed", "the close lost the typed name")
    }

    /// New Bin takes the first number that no bin name has, with the English name format. The test
    /// process has no tables, so the window gives each new bin the key as its name.
    @Test func newBinTakesAFreeName() throws {
        let format = try #require(try stringsTable("en")[L10n.binsNewName.rawValue])
        let name: (Int) -> String = { String(format: format, locale: .current, $0) }
        var session = Session(sampleRate: 48_000)
        #expect(SessionWindow.newBinName(session, name: name) == "Bin 1")
        try session.addBin(named: "Bin 2")
        #expect(SessionWindow.newBinName(session, name: name) == "Bin 1", "a second bin named Bin 2")
        try session.addBin(named: "Bin 1")
        #expect(SessionWindow.newBinName(session, name: name) == "Bin 3")
    }
}
