import AppKit
import DirigibleCore
import Testing

@testable import DirigibleApp

/// Criterion 24: Command-Z in a track name field undoes the typing, not a session edit (P12).
/// The test sends `undo:` along the responder chain from the first responder, the path of the
/// Undo menu item in a key window.
@MainActor struct UndoRoutingTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws { folder = try TemporaryFolder() }

    @Test func undoInATrackNameFieldUndoesTheTyping() async throws {
        let (model, window) = try await openWithOneTrack()
        let field = try #require(await nameField(in: window))
        #expect(window.makeFirstResponder(field))
        let editor = try #require(window.fieldEditor(false, for: field) as? NSTextView)
        editor.insertText("Host", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.string != "Track 1")

        #expect(window.firstResponder?.tryToPerform(#selector(UndoRoutingWindow.undo(_:)), with: nil) == true)
        #expect(editor.string == "Track 1")
        #expect(model.studio?.session.tracks.count == 1)
        await model.close()
    }

    /// The control: with no text field focused, Undo undoes the add track.
    @Test func undoWithNoFieldFocusedUndoesTheSessionEdit() async throws {
        let (model, window) = try await openWithOneTrack()
        #expect(window.makeFirstResponder(nil))
        #expect(window.firstResponder?.tryToPerform(#selector(UndoRoutingWindow.undo(_:)), with: nil) == true)
        #expect(model.studio?.session.tracks.count == 0)
        await model.close()
    }

    /// C11: after an agent edit, Undo names the agent; after its undo, Redo names it. A user edit
    /// gives the plain titles, and an agent with no valid name gives "Agent".
    @Test func undoTitleNamesTheAgent() async throws {
        let (model, window) = try await openWithOneTrack()
        #expect(window.makeFirstResponder(nil))
        let studio = try #require(model.studio)
        let undo = NSMenuItem(title: "Undo", action: #selector(UndoRoutingWindow.undo(_:)), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: #selector(UndoRoutingWindow.redo(_:)), keyEquivalent: "Z")
        let plain = (UndoManager().undoMenuItemTitle, UndoManager().redoMenuItemTitle)

        try studio.edit(agent: AgentName(title: "Claude Code", clientName: "claude-code")) { s throws(SessionError) in
            try s.renameTrack("t1", to: "Host")
        }
        #expect(window.validateMenuItem(undo))
        #expect(undo.title == L10n.undoAgent.format("Claude Code"), "C11: \(undo.title)")
        try studio.undo()
        #expect(window.validateMenuItem(redo))
        #expect(redo.title == L10n.redoAgent.format("Claude Code"))
        #expect(window.validateMenuItem(undo))
        #expect(undo.title == plain.0, "the add track of the user")

        try studio.edit(agent: AgentName(title: nil, clientName: "\n")) { s throws(SessionError) in
            try s.renameTrack("t1", to: "Guest")
        }
        #expect(window.validateMenuItem(undo))
        #expect(undo.title == L10n.undoAgentUnnamed.text)
        #expect(!window.validateMenuItem(redo))
        #expect(redo.title == plain.1)
        await model.close()
    }

    @Test func aTextViewIsTheTextTargetAndAnythingElseTheSession() {
        #expect(undoTarget(firstResponder: NSTextView()) == .text)
        #expect(undoTarget(firstResponder: nil) == .session)
        #expect(undoTarget(firstResponder: NSWindow()) == .session)
    }

    private func openWithOneTrack() async throws -> (SessionWindow, NSWindow) {
        let model = await app.open(try folder.package("undo"))
        let studio = try #require(await model.opened() ? model.studio : nil)
        try studio.edit { s throws(SessionError) in try s.addTrack("t1", name: "Track 1", layout: .mono) }
        return (model, try #require(model.window))
    }

    /// The first editable text field of the window, after SwiftUI draws the track row.
    private func nameField(in window: NSWindow) async -> NSTextField? {
        var found: NSTextField?
        await until("the track row shows its name field") {
            window.contentView?.layoutSubtreeIfNeeded()
            found = window.contentView.flatMap(firstField)
            return found != nil
        }
        return found
    }

    private func firstField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        return view.subviews.lazy.compactMap(firstField).first
    }
}
