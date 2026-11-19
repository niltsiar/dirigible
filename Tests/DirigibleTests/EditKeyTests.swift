import AppKit
import DirigibleCore
import DirigibleTimeline
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
        let edit = TimelineCommand.pasteboardItems + TimelineCommand.rippleItems + TimelineCommand.editItems
        let command = EventModifiers.command.rawValue
        #expect(
            edit.map { "\($0.command) \($0.key.character) \($0.modifiers.rawValue)" } == [
                "cut x \(command)", "copy c \(command)", "paste v \(command)",
                "fill v \(EventModifiers([.command, .option]).rawValue)", "insert i \(command)",
                "replace v \(EventModifiers([.command, .shift]).rawValue)", "delete \u{8} 0",
                "deleteCloseGap \u{8} \(EventModifiers.shift.rawValue)", "selectAll a \(command)",
                "cutSelectedTracks x \(EventModifiers([.command, .option]).rawValue)",
                "deleteCloseGapSelectedTracks \u{8} \(EventModifiers([.shift, .option]).rawValue)", "setIn i 0",
                "setOut o 0",
                "deselectAll a \(EventModifiers([.command, .shift]).rawValue)", "split b \(command)",
                "nudgeLeft \u{F702} \(command)", "nudgeRight \u{F703} \(command)",
                "rollToPlayhead x \(EventModifiers.shift.rawValue)",
                "slipLeft \u{F702} \(EventModifiers([.shift, .option]).rawValue)",
                "slipRight \u{F703} \(EventModifiers([.shift, .option]).rawValue)", "fade f \(command)",
                "addGainPoint k \(EventModifiers.option.rawValue)",
            ])
        let shift = EventModifiers.shift.rawValue
        let control = EventModifiers.control.rawValue
        #expect(
            TimelineCommand.markerItems.map { "\($0.command) \($0.key.character) \($0.modifiers.rawValue)" } == [
                "addMarker \r \(command)", "addChapter \r \(EventModifiers([.command, .shift]).rawValue)",
                "markerInfo \r \(shift)", "moveMarker \r \(EventModifiers([.command, .option]).rawValue)",
                "deleteMarker \u{8} \(command)", "previousMarker \u{F72C} 0", "nextMarker \u{F72D} 0",
            ])
        #expect(
            (TimelineCommand.trackItems + TimelineCommand.fileItems).map {
                "\($0.command) \($0.key.character) \($0.modifiers.rawValue)"
            } == [
                "renameTrack \r 0", "removeTrack \u{8} \(EventModifiers([.command, .option]).rawValue)",
                "muteTracks m \(shift)", "soloTracks s \(shift)", "raiseVolume = \(control)",
                "lowerVolume - \(control)", "resetVolume 0 \(control)", "importAudio t \(command)",
                "showInFinder r \(EventModifiers([.command, .shift]).rawValue)", "export e \(command)",
                "exportSelection e \(EventModifiers([.command, .shift]).rawValue)",
                "exportChapters e \(EventModifiers([.command, .option]).rawValue)",
                "episodeInfo i \(EventModifiers([.command, .shift]).rawValue)",
            ])
        #expect(
            TimelineCommand.toolItems.map { "\($0.command) \($0.key.character) \($0.modifiers.rawValue)" } == [
                "autoLevel l \(command)", "autoLevelPerTrack l \(EventModifiers([.command, .option]).rawValue)",
                "levelOverTime l \(EventModifiers([.command, .shift]).rawValue)",
                "syncClip g \(EventModifiers([.command, .option]).rawValue)",
            ])
        #expect(TimelineCommand.menuItems[.syncClip]?.title == .menuToolsSyncClip)
        #expect(
            [TimelineCommand.splitStereoItem].map { "\($0.command) \($0.key.character) \($0.modifiers.rawValue)" }
                == ["splitStereo d \(EventModifiers([.command, .shift]).rawValue)"])
        // Decision 0057 D6: Tools > Restore Original Audio, a menu item with its key.
        #expect(
            [TimelineCommand.restoreOriginalItem].map { "\($0.command) \($0.key.character) \($0.modifiers.rawValue)" }
                == ["restoreOriginal o \(EventModifiers([.command, .shift]).rawValue)"])
        #expect(TimelineCommand.menuItems[.restoreOriginal]?.title == .menuToolsRestoreOriginal)
        #expect(
            TimelineCommand.gainPointSeekItems.map { "\($0.command) \($0.key.character) \($0.modifiers.rawValue)" }
                == [
                    "previousGainPoint ; \(EventModifiers.option.rawValue)",
                    "nextGainPoint ' \(EventModifiers.option.rawValue)",
                ])
        let items =
            TimelineCommand.viewItems + edit + TimelineCommand.markerItems + TimelineCommand.trackItems
            + TimelineCommand.fileItems + TimelineCommand.toolItems + [TimelineCommand.splitStereoItem]
            + [TimelineCommand.restoreOriginalItem] + TimelineCommand.gainPointSeekItems
        #expect(Set(items.map(\.title)).count == items.count)
        let keys = items.map { KeyboardShortcut($0.key, modifiers: $0.modifiers) } + MenuKeys.all
        #expect(KeyRule.problems(keys) == [])
        // Record monitor run 1b, B13: Track > Monitor Track, next to Shift-Command-M of Input Levels.
        #expect(MenuKeys.monitorTrack == KeyboardShortcut("m", modifiers: [.command, .control]), "Monitor Track")
        #expect(MenuKeys.all.contains(MenuKeys.monitorTrack), "the key rule checks Monitor Track")
        #expect(MenuKeys.transcript == KeyboardShortcut("t", modifiers: [.command, .shift]), "Show Transcript")
        #expect(MenuKeys.all.contains(MenuKeys.transcript), "the key rule checks Show Transcript")
    }

    /// Timeline-navigation N17 (U6, probe K1, plan gate item 2): a symbol or digit key with Shift
    /// and without Shift is one key at run time, a shifted character with a modifier is no key, and
    /// the reserved system keys count. Space, Return, Delete, and the arrows keep Shift.
    @Test func theKeyRuleFindsTheRunTimeRepeats() {
        let command = KeyboardShortcut("+")
        #expect(
            KeyRule.problems([command, KeyboardShortcut("+", modifiers: [.command, .shift])]) == ["repeat: + ⇧⌘"],
            "Shift-Command-plus repeats Command-plus")
        #expect(KeyRule.problems([KeyboardShortcut("_")]) == ["shifted character: _"])
        #expect(KeyRule.problems([KeyboardShortcut("*", modifiers: [.command, .shift])]) == ["shifted character: *"])
        // Vari-speed V8: a plain ">" item gets the typed ">" on the US and Spanish layouts.
        #expect(KeyRule.problems([KeyboardShortcut(">", modifiers: [])]) == [])
        #expect(
            KeyRule.problems([KeyboardShortcut("=", modifiers: [.command, .option])] + MenuKeys.all)
                == ["repeat: = ⌥⌘"], "Option-Command-= is a system key")
        // Code gate 1 item 9: the window takes Command-= (U1), so no menu item can have it.
        #expect(KeyRule.problems([KeyboardShortcut("=")] + MenuKeys.all) == ["repeat: = ⌘"], "Command-= is a key")
        #expect(
            KeyRule.problems([KeyboardShortcut(.space, modifiers: [.command, .control])] + MenuKeys.all)
                == ["repeat: \u{20} ⌃⌘"], "Control-Command-Space is a system key")
        #expect(
            KeyRule.problems([
                KeyboardShortcut(.space, modifiers: []), KeyboardShortcut(.space, modifiers: .shift),
                KeyboardShortcut(.return), KeyboardShortcut(.return, modifiers: [.command, .shift]),
                KeyboardShortcut(.leftArrow), KeyboardShortcut(.leftArrow, modifiers: [.command, .shift]),
            ]) == [], "Shift-Space and Space are two keys")
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

    /// C16 (UQ5 b): with a name field focused, the key of Replace or of Paste to Fill Selection goes to
    /// the field first. The session, the playhead, and the Marks stay, and so does the text. Control:
    /// with no forward, the command edits the session.
    func aFocusedFieldTakes(_ command: TimelineCommand, flags: NSEvent.ModifierFlags) async throws {
        let (model, studio, window, _) = try await openLanes(
            app, try await timelinePackage(in: folder.url, tracks: 2, seconds: 60))
        model.timeline.marks = Marks(inPoint: 0, outPoint: 48_000, tracks: ["t1"])
        model.run(.copy)
        try #require(model.clipboard != nil)
        let marks = Marks(inPoint: 96_000, outPoint: 192_000, tracks: ["t2"])
        model.timeline.marks = marks
        await studio.perform(.seek(.frame(24_000)))
        let editor = try await focusName(in: window)
        editor.setSelectedRange(NSRange(location: 1, length: 0))
        let (session, playhead, text) = (studio.session, studio.playhead, editor.string)
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))

        app.timeline(command, event: event, in: window)

        #expect(studio.session == session && studio.playhead == playhead && !studio.canUndo)
        #expect(model.timeline.marks == marks && model.importJob == nil)
        #expect(editor.string == text && window.firstResponder === editor)
        await model.close()
    }

    @Test func replaceKeyGoesToAFocusedField() async throws {
        try await aFocusedFieldTakes(.replace, flags: [.command, .shift])
    }

    @Test func fillKeyGoesToAFocusedField() async throws {
        try await aFocusedFieldTakes(.fill, flags: [.command, .option])
    }

    /// Criterion 14: with a name field focused, the marker keys change no marker, no playhead, and
    /// no rename state. Control: with no
    /// forward, each command runs (a new marker, a moved or deleted m1, the rename state, or the
    /// current marker of Next and Previous).
    @Test func markerKeysGoToAFocusedField() async throws {
        let (model, studio, window, _) = try await openLanes(
            app, try await timelinePackage(in: folder.url, tracks: 2, seconds: 60))
        try studio.edit(ripple: false) { s throws(SessionError) in
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
            (.markerInfo, returnKey(.shift)), (.moveMarker, returnKey([.command, .option])),
            (.deleteMarker, commandKey("\u{7F}", code: 51, in: window)),
        ]

        for (command, event) in keys {
            model.timeline.marker = command == .nextMarker || command == .previousMarker ? nil : "m1"
            app.timeline(command, event: event, in: window)
            #expect(
                model.timeline.marker == (command == .nextMarker || command == .previousMarker ? nil : "m1"),
                "\(command)")
            #expect(model.inspectorTab != .marker, "\(command)")
        }

        #expect(studio.session == session && studio.playhead == playhead)
        // Shift-Return ends the edit and selects the text; Command-Backspace deletes it. So both
        // keys reached the field.
        #expect(window.firstResponder === editor && editor.string == "")
        await model.close()
    }

    /// Criterion 14: with a name field focused, Option-Command-Backspace and Shift-Command-R change
    /// no track and reveal nothing. Control: with no forward, t1 goes, and the reveal gets f1.
    /// The session check comes before the wait: a remove is synchronous, and an end of the edit
    /// during the wait saves the typed name, as designed.
    @Test func removeTrackAndShowInFinderKeysGoToAFocusedField() async throws {
        let (model, studio, window, _) = try await openLanes(
            app, try await timelinePackage(in: folder.url, tracks: 2, seconds: 60, audio: true))
        var revealed = 0
        app.reveal = { _ in revealed += 1 }
        model.timeline.marks = Marks(tracks: ["t1"])
        let editor = try await focusName(in: window)
        let session = studio.session

        app.timeline(.removeTrack, event: commandKey("\u{7F}", code: 51, in: window), in: window)
        app.timeline(.showInFinder, event: commandKey("R", code: 15, in: window), in: window)

        #expect(studio.session == session)
        #expect(editor.string == "")
        // A reveal reads the disk off the main actor first; give a wrong one the time to arrive.
        try await Task.sleep(for: .milliseconds(300))
        #expect(revealed == 0)
        await model.close()
    }

    /// C11 (the K1 method of decision 0025): an AppKit menu with the keys of the gain point items
    /// takes Option-K, and Option-; and Option-' on the US layout and on the Spanish layout, where
    /// ";" is Shift-comma and "'" is the key right of 0. On screen, the automatic key localization
    /// moves a punctuation key, so each item keeps the typed character.
    @Test func theGainPointKeysReachTheirItemsOnTheUSAndTheSpanishLayouts() {
        // A menu item sends its action through NSApp, and NSApp stays nil until something makes it.
        _ = NSApplication.shared
        let menu = NSMenu()
        var fired: [String] = []
        final class Target: NSObject {
            var action: (String) -> Void = { _ in }
            @objc func fire(_ item: NSMenuItem) { action(item.title) }
        }
        let target = Target()
        target.action = { fired.append($0) }
        let items =
            TimelineCommand.editItems.filter { $0.command == .addGainPoint } + TimelineCommand.gainPointSeekItems
        for item in items {
            let menuItem = NSMenuItem(
                title: "\(item.command)", action: #selector(Target.fire(_:)), keyEquivalent: String(item.key.character))
            menuItem.keyEquivalentModifierMask = NSEvent.ModifierFlags(item.modifiers)
            menuItem.target = target
            menu.addItem(menuItem)
        }
        func chord(_ characters: String, _ flags: NSEvent.ModifierFlags, code: UInt16) -> NSEvent {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        }

        #expect(menu.performKeyEquivalent(with: chord("k", .option, code: 40)), "Option-K")
        #expect(menu.performKeyEquivalent(with: chord(";", .option, code: 41)), "the US Option-;")
        #expect(menu.performKeyEquivalent(with: chord("'", .option, code: 39)), "the US Option-'")
        #expect(
            menu.performKeyEquivalent(with: chord(";", [.option, .shift], code: 43)), "the Spanish Option-Shift-comma")
        #expect(menu.performKeyEquivalent(with: chord("'", .option, code: 27)), "the Spanish Option-'")
        #expect(
            items.allSatisfy { "\($0.command.keyLocalization)" == "\(KeyboardShortcut.Localization.custom)" },
            "the menu keeps the typed characters")
        #expect(
            fired == ["addGainPoint", "previousGainPoint", "nextGainPoint", "previousGainPoint", "nextGainPoint"],
            "each chord reaches its item: \(fired)")
    }
}

/// The key check of the menus (timeline-navigation N17). A key equivalent matches the characters
/// of the event (probe K1): the US Shift-Command-= gives "+" and reaches Command-"+". So Shift does
/// not count for a printable symbol or digit key, and a character that needs Shift or Option on
/// both the US and the Spanish layout is no key with Command, Option, or Control. With no modifier
/// the item matches the typed character (`SpeedKeyTests.spanishISOKeysStepTheSpeed`). Letters, Space, Return, Delete, the arrows,
/// and the function keys keep Shift.
enum KeyRule {
    static let shifted = Set("!\"#$%&()*:>?@^_{|}~")

    static func problems(_ keys: [KeyboardShortcut]) -> [String] {
        func name(_ key: KeyboardShortcut) -> String {
            var flags = ""
            if key.modifiers.contains(.control) { flags += "⌃" }
            if key.modifiers.contains(.option) { flags += "⌥" }
            if key.modifiers.contains(.shift) { flags += "⇧" }
            if key.modifiers.contains(.command) { flags += "⌘" }
            return "\(key.key.character) \(flags)"
        }
        func normal(_ key: KeyboardShortcut) -> KeyboardShortcut {
            let character = key.key.character
            let symbol = character.isASCII && (character.isPunctuation || character.isSymbol || character.isNumber)
            return symbol ? KeyboardShortcut(key.key, modifiers: key.modifiers.subtracting(.shift)) : key
        }
        let refused = keys.filter { shifted.contains($0.key.character) && !$0.modifiers.isEmpty }.map {
            "shifted character: \($0.key.character)"
        }
        let groups = Dictionary(grouping: keys, by: normal).filter { $0.value.count > 1 }
        return refused + groups.values.map { "repeat: \(name($0[1]))" }.sorted()
    }
}
