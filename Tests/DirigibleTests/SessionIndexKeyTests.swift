import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Find in Session Index (Shift-Command-F) and the keys of the search field. The fixture is that of
/// `SessionIndexWindowTests`: the rows are a (0), h1 "Intro" (1), m1 "Breath" (2), b (3), c (4), and m2 "Cut here" (5).
@Suite(.serialized) @MainActor struct SessionIndexKeyTests {
    let windows: SessionIndexWindowTests

    init() throws { windows = try SessionIndexWindowTests() }

    func event(_ characters: String, code: UInt16, in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
            keyCode: code)!
    }

    func fieldHasFocus(_ model: SessionWindow, _ window: NSWindow) -> Bool {
        guard let field = (window.firstResponder as? NSTextView)?.delegate as? NSTextField else { return false }
        return field === model.indexSearchField
    }

    func open(shown: Bool) async throws -> (SessionWindow, Studio, NSWindow) {
        let (model, studio, window) = try await windows.open(shown: shown)
        windows.app.key = model
        window.makeKeyAndOrderFront(nil)
        return (model, studio, window)
    }

    /// The menu item and its key come to this call, as `transport(_:)` does for a transport key.
    func find(_ model: SessionWindow, in window: NSWindow) async {
        windows.app.findInIndex()
        await until(limit: .seconds(5), "the search field has the focus") {
            window.contentView?.layoutSubtreeIfNeeded()
            return model.leadingPane.shown && fieldHasFocus(model, window)
        }
    }

    @Test func findShowsTheIndexAndFocusesTheField() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, _, window) = try await open(shown: false)
        try #require(window.makeFirstResponder(model.timelineView?.lanes), "the lanes have the focus")
        await find(model, in: window)
        #expect(windows.defaults.bool(forKey: LeadingPaneState.shownKey), "the shown state is saved")
        await model.close()
    }

    @Test func findWithThePaneShownFocusesTheFieldAndKeepsThePane() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, _, window) = try await open(shown: true)
        try #require(window.makeFirstResponder(model.timelineView?.lanes), "the lanes have the focus")
        try #require(!fieldHasFocus(model, window))
        await find(model, in: window)
        #expect(model.leadingPane.shown, "Find keeps the shown pane")

        await find(model, in: window)
        #expect(model.leadingPane.shown && fieldHasFocus(model, window), "a second Find keeps the pane and the focus")
        await model.close()
    }

    @Test func aHideWithTheFieldFocusedGivesTheLanesTheFocus() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, _, window) = try await open(shown: true)
        await find(model, in: window)
        model.toggleIndex()
        #expect(!model.leadingPane.shown, "the toggle hides the pane")
        #expect(window.firstResponder === model.timelineView?.lanes, "the lanes took the focus from the hidden field")
        await model.close()
    }

    @Test func findFromAnInspectorFieldMovesTheFocus() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, _, window) = try await open(shown: true)
        model.showEpisodeInfo()
        var inspectorField: NSTextField?
        await until("the inspector shows a field") {
            window.contentView?.layoutSubtreeIfNeeded()
            inspectorField = windows.views(NSTextField.self, in: window.contentView).first {
                $0.isEditable && windows.frame($0).minX > window.contentLayoutRect.width - 420
            }
            return inspectorField != nil
        }
        try #require(window.makeFirstResponder(inspectorField), "the inspector field has the focus")
        try #require(!fieldHasFocus(model, window))
        await find(model, in: window)
        await model.close()
    }

    @Test func theFieldTakesThePlainKeys() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, studio, window) = try await open(shown: true)
        let app = windows.app
        try #require(window.makeFirstResponder(model.timelineView?.lanes))

        // The near input: with the focus in the lanes, I sets the In point.
        let before = model.timeline.selection
        app.timeline(.setIn, event: event("i", code: 34, in: window), in: window)
        try #require(model.timeline.selection != before, "I in the lanes did not set the In point")
        model.run(.deselectAll)

        await find(model, in: window)
        let (selection, snaps) = (model.timeline.selection, app.snaps)
        app.timeline(.setIn, event: event("i", code: 34, in: window), in: window)
        app.timeline(.setOut, event: event("o", code: 31, in: window), in: window)
        app.toggleSnap(event: event("n", code: 45, in: window), in: window)
        app.timeline(.zoomToSelection, event: event("h", code: 4, in: window), in: window)
        app.speed(.toggle, event: event(".", code: 47, in: window), in: window)
        app.transport(.playStop, event: event(" ", code: 49, in: window), in: window)
        #expect(model.leadingPane.search == "ionh. ", "the keys typed: \"\(model.leadingPane.search)\"")
        app.timeline(.delete, event: event("\u{7f}", code: 51, in: window), in: window)
        #expect(model.leadingPane.search == "ionh.", "Backspace deleted one character")

        #expect(model.timeline.selection == selection, "a key set a Mark")
        #expect(app.snaps == snaps, "N toggled Snap")
        #expect(studio.playback == .stopped && studio.speed == .one, "Space or the period ran a transport command")
        #expect(!studio.canUndo, "Backspace edited the session")
        await model.close()
    }

    @Test func escClearsTheTextThenGivesTheFocusToTheLanes() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, _, window) = try await open(shown: true)
        await find(model, in: window)
        model.leadingPane.search = "cut"
        window.sendEvent(event("\u{1B}", code: 53, in: window))
        #expect(model.leadingPane.search.isEmpty, "Esc with text clears it")
        #expect(fieldHasFocus(model, window), "the first Esc keeps the focus in the field")

        window.sendEvent(event("\u{1B}", code: 53, in: window))
        #expect(window.firstResponder === model.timelineView?.lanes, "Esc with no text gives the focus to the lanes")
        await model.close()
    }

    @Test func downArrowMovesTheFocusToTheFirstRow() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, _, window) = try await open(shown: true)
        let table = try #require(model.leadingPane.table)
        await until("the table shows its rows") { table.numberOfRows == 6 }
        await find(model, in: window)
        window.sendEvent(event("\u{F701}", code: 125, in: window))
        #expect(window.firstResponder === table, "Down Arrow gives the list the focus")
        #expect(table.selectedRow == 0 && model.timeline.selectedRows.count == 1, "the first row is selected")
        await model.close()
    }
}
