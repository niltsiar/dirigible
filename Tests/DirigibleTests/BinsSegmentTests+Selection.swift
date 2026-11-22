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
        await until("the list drops the row") { table.numberOfRows == 1 }

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
        await until("the list drops the new row") { table.numberOfRows == 2 }

        #expect(model.leadingPane.binRename == nil, "the rename of the removed item stays open")
        #expect(model.leadingPane.selectedBinItem == nil, "the pane keeps the removed item")
        #expect(studio.session.bins.first?.items.map(\.name) == ["Jingle"], "the end of the rename made an edit")
        #expect(model.binsListHasFocus(in: window), "the keys do not go to the list")
        await model.close()
    }
}
