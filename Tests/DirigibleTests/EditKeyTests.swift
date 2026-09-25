import AppKit
import DirigibleCore
import SwiftUI
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Edit-commands criteria 12 and 14: the keys of the menu items, and the keys that a focused text
/// field keeps.
@Suite(.serialized) @MainActor struct EditKeyTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws { folder = try TemporaryFolder() }

    /// F16. The menus are built from these tables. Control: a second item on Command-C fails.
    @Test func everyItemHasItsKeyAndNoKeyRepeats() {
        let edit = TimelineCommand.pasteboardItems + TimelineCommand.editItems
        let command = EventModifiers.command.rawValue
        #expect(
            edit.map { "\($0.command) \($0.key.character) \($0.modifiers.rawValue)" } == [
                "cut x \(command)", "copy c \(command)", "paste v \(command)", "delete \u{8} 0",
                "selectAll a \(command)", "setIn i 0", "setOut o 0",
                "deselectAll a \(EventModifiers([.command, .shift]).rawValue)", "split b \(command)",
                "nudgeLeft \u{F702} \(command)", "nudgeRight \u{F703} \(command)",
            ])
        let items = TimelineCommand.viewItems + edit
        #expect(Set(items.map(\.title)).count == items.count)
        let keys = items.map { KeyboardShortcut($0.key, modifiers: $0.modifiers) } + MenuKeys.all
        let repeated = Dictionary(grouping: keys) { $0 }.filter { $0.value.count > 1 }.keys
        #expect(repeated.isEmpty, "keys on two items: \(repeated.map { "\($0.key.character) \($0.modifiers)" })")
    }

    /// Criterion 14: Backspace deletes one character of a focused field, and the session and the
    /// Marks stay. Control: with no forward, delete: removes no character (probe E4c).
    @Test func backspaceGoesToAFocusedField() async throws {
        let (model, studio, window, _) = try await openLanes(
            app, try await timelinePackage(in: folder.url, tracks: 2, seconds: 60))
        let marks = Marks(inPoint: 0, outPoint: 48_000, tracks: ["t1"])
        model.timeline.marks = marks
        let editor = try await focusName(in: window)
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        let session = studio.session

        app.timeline(.delete, event: key(.keyDown, "\u{7F}", code: 51, in: window), in: window)

        #expect(editor.string == "T")
        #expect(studio.session == session && model.timeline.marks == marks)
        await model.close()
    }

    /// Criterion 14: Command-Left and Command-Right move the caret of a focused field, and Command-B
    /// goes there too; the session, the playhead, and the Marks stay. Control: with no forward, the
    /// caret stays, Split cuts t1, and Nudge Right moves c1.
    @Test func cmdArrowsAndCmdBGoToAFocusedField() async throws {
        let (model, studio, window, _) = try await openLanes(
            app, try await timelinePackage(in: folder.url, tracks: 2, seconds: 60))
        await studio.perform(.seek(.frame(96_000)))
        let editor = try await focusName(in: window)
        editor.setSelectedRange(NSRange(location: 1, length: 0))
        let (session, playhead) = (studio.session, studio.playhead)
        let arrows: [(TimelineCommand, UInt16, String, Int)] = [
            (.nudgeLeft, 123, "\u{F702}", 0), (.nudgeRight, 124, "\u{F703}", 2),
        ]

        for (command, code, characters, caret) in arrows {
            model.timeline.marks = Marks(inPoint: 0, outPoint: 2_880_000, tracks: ["t1"])
            app.timeline(command, event: commandKey(characters, code: code, in: window), in: window)
            #expect(editor.selectedRange() == NSRange(location: caret, length: 0), "\(command)")
        }
        model.timeline.marks = Marks(inPoint: 48_000, outPoint: 96_000, tracks: ["t1"])
        app.timeline(.split, event: commandKey("b", code: 11, in: window), in: window)

        #expect(studio.session == session && studio.playhead == playhead)
        #expect(model.timeline.marks == Marks(inPoint: 48_000, outPoint: 96_000, tracks: ["t1"]))
        await model.close()
    }
}
