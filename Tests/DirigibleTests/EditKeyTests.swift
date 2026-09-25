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
        let shift = EventModifiers.shift.rawValue
        #expect(
            TimelineCommand.markerItems.map { "\($0.command) \($0.key.character) \($0.modifiers.rawValue)" } == [
                "addMarker \r \(command)", "addChapter \r \(EventModifiers([.command, .shift]).rawValue)",
                "renameMarker \r \(shift)", "moveMarker \r \(EventModifiers([.command, .option]).rawValue)",
                "deleteMarker \u{8} \(command)", "previousMarker \u{F72C} 0", "nextMarker \u{F72D} 0",
            ])
        #expect(
            (TimelineCommand.trackItems + TimelineCommand.fileItems).map {
                "\($0.command) \($0.key.character) \($0.modifiers.rawValue)"
            } == [
                "removeTrack \u{8} \(EventModifiers([.command, .option]).rawValue)",
                "showInFinder r \(EventModifiers([.command, .shift]).rawValue)", "export e \(command)",
                "exportSelection e \(EventModifiers([.command, .shift]).rawValue)",
            ])
        let items =
            TimelineCommand.viewItems + edit + TimelineCommand.markerItems + TimelineCommand.trackItems
            + TimelineCommand.fileItems
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

    /// Criterion 14: with a name field focused, the marker keys change no marker, no playhead, and
    /// no rename state. Control: with no
    /// forward, each command runs (a new marker, a moved or deleted m1, the rename state, or the
    /// current marker of Next and Previous).
    @Test func markerKeysGoToAFocusedField() async throws {
        let (model, studio, window, _) = try await openLanes(
            app, try await timelinePackage(in: folder.url, tracks: 2, seconds: 60))
        try studio.edit { s throws(SessionError) in
            try s.setMarker(Marker(id: "m1", name: "One", position: 48_000, kind: .marker))
            try s.setMarker(Marker(id: "m2", name: "Two", position: 96_000, kind: .marker))
        }
        await studio.perform(.seek(.frame(72_000)))
        let editor = try await focusName(in: window)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        let (session, playhead) = (studio.session, studio.playhead)
        let returnKey = { (flags: NSEvent.ModifierFlags) in
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                isARepeat: false, keyCode: 36)!
        }
        let keys: [(TimelineCommand, NSEvent)] = [
            (.nextMarker, key(.keyDown, "\u{F72D}", code: 121, in: window)),
            (.previousMarker, key(.keyDown, "\u{F72C}", code: 116, in: window)),
            (.addMarker, returnKey(.command)), (.addChapter, returnKey([.command, .shift])),
            (.renameMarker, returnKey(.shift)), (.moveMarker, returnKey([.command, .option])),
            (.deleteMarker, commandKey("\u{7F}", code: 51, in: window)),
        ]

        for (command, event) in keys {
            model.timeline.marker = command == .nextMarker || command == .previousMarker ? nil : "m1"
            app.timeline(command, event: event, in: window)
            #expect(
                model.timeline.marker == (command == .nextMarker || command == .previousMarker ? nil : "m1"),
                "\(command)")
            #expect(model.timeline.renaming == nil, "\(command)")
        }

        #expect(studio.session == session && studio.playhead == playhead)
        // Shift-Return ends the edit and selects the text; Command-Backspace deletes it. So both
        // keys reached the field.
        #expect(window.firstResponder === editor && editor.string == "")
        await model.close()
    }

    /// Criterion 14: with a name field focused, Option-Command-Backspace and Shift-Command-R change
    /// no track and reveal nothing. Control: with no forward, t1 goes, and the reveal gets f1.
    @Test func removeTrackAndShowInFinderKeysGoToAFocusedField() async throws {
        let (model, studio, window, _) = try await openLanes(
            app, try await timelinePackage(in: folder.url, tracks: 2, seconds: 60, audio: true))
        var revealed = 0
        app.reveal = { _ in revealed += 1 }
        model.timeline.marks = Marks(tracks: ["t1"])
        _ = try await focusName(in: window)
        let session = studio.session

        app.timeline(.removeTrack, event: commandKey("\u{7F}", code: 51, in: window), in: window)
        app.timeline(.showInFinder, event: commandKey("R", code: 15, in: window), in: window)
        // A reveal reads the disk off the main actor first; give a wrong one the time to arrive.
        try await Task.sleep(for: .milliseconds(300))

        #expect(studio.session == session && revealed == 0)
        await model.close()
    }
}
