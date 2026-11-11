import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Return and Delete with the Silences list as first responder (decision 0066, criterion C33).
extension SilencesInspectorTests {
    /// The table of the Silences list, once the inspector draws it: the window has the index table too.
    func list(in window: NSWindow) -> NSTableView? {
        window.contentView?.layoutSubtreeIfNeeded()
        return (window as? UndoRoutingWindow)?.model?.silences.table
    }

    /// The window with a scanned list, the list as first responder, and the track t1 selected, so a
    /// Return that reaches Track > Rename starts a rename.
    func focusedList(_ name: String) async throws -> (SessionWindow, Studio, NSWindow, NSTableView) {
        let (model, studio) = try await open(try await package(name))
        let window = try #require(model.window)
        app.key = model
        await model.findSilences()
        await until("the list shows") { list(in: window) != nil }
        let table = try #require(list(in: window))
        model.clickHeader("t1", flags: [])
        #expect(window.makeFirstResponder(table), "the list takes the focus")
        return (model, studio, window, table)
    }

    func editableFields(in view: NSView?) -> [NSTextField] {
        guard let view else { return [] }
        let own = (view as? NSTextField).map { $0.isEditable ? [$0] : [] } ?? []
        return own + view.subviews.flatMap { editableFields(in: $0) }
    }

    func returnKey(in window: NSWindow) -> NSEvent { key(.keyDown, "\r", code: 36, in: window) }

    /// C33: Return with the list as first responder applies when Apply is on; with Apply off it does
    /// nothing, and no rename starts. Return elsewhere keeps its meaning (Rename Track), and
    /// Return in the keep field changes only the field.
    @Test func returnInTheListAppliesOnlyWhenApplyIsOn() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, studio, window, _) = try await focusedList("return")
        try #require(model.canApplySilences)

        model.setSilenceAction(.skip, rows: [0, 1])
        try #require(!model.canApplySilences)
        app.timeline(.renameTrack, event: returnKey(in: window), in: window)
        #expect(model.renamingTrack == nil, "Return with Apply off started a rename")
        model.renamingTrack = nil
        #expect(!studio.canUndo && model.silences.note == nil, "Return with Apply off applied")
        model.setSilenceAction(.shorten, rows: [0, 1])

        let keep = try #require(
            editableFields(in: window.contentView).first { $0.stringValue == model.silences.keepText })
        #expect(window.makeFirstResponder(keep), "the keep field takes the focus")
        app.timeline(.renameTrack, event: returnKey(in: window), in: window)
        #expect(!studio.canUndo && model.silences.review != nil, "Return in the keep field applied")
        #expect(model.renamingTrack == nil, "Return in the keep field started a rename")

        let table = try #require(list(in: window))
        try #require(window.makeFirstResponder(table))
        app.timeline(.renameTrack, event: returnKey(in: window), in: window)
        #expect(studio.canUndo && studio.session.end == 312_000, "Return in the list did not apply")
        #expect(model.silences.note != nil && model.renamingTrack == nil, "\(String(describing: model.renamingTrack))")

        #expect(window.makeFirstResponder(model.timelineView?.lanes))
        model.clickHeader("t1", flags: [])
        app.timeline(.renameTrack, event: returnKey(in: window), in: window)
        #expect(model.renamingTrack == "t1", "Return in the lanes lost its meaning")
        await model.close()
    }

    /// C33: Delete with the list as first responder sets the selected rows to Skip and edits no clip.
    @Test func deleteInTheListSetsTheSelectedRowsToSkip() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, studio, window, _) = try await focusedList("delete")
        model.selectSilences([0])
        app.timeline(.delete, event: key(.keyDown, "\u{7f}", code: 51, in: window), in: window)
        #expect(rows(model).map(\.action) == [.skip, .shorten], "\(rows(model))")
        #expect(!studio.canUndo, "Delete edited the session")
        await model.close()
    }
}
