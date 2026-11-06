import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import SwiftUI
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// C18: the keys of Roll Edit to Playhead (Shift-X), Slip Content Left (Shift-Option-Left), and
/// Slip Content Right (Shift-Option-Right) with and without a focused track name field. Close Gaps
/// has no key. Track t1 holds c1 at 0 ..< 48,000, c2 at 48,000 ..< 96,000, and c3 at 96,000 ..< 144,000, all touching.
@Suite(.serialized) @MainActor struct TimelineEditKeyTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws { folder = try TemporaryFolder() }

    func package() async throws -> URL {
        let url = try await timelinePackage(in: folder.url, tracks: 1, seconds: 3)
        var session = try Session(contentsOf: url)
        _ = try session.split("c1", at: 48_000, rightID: "c2")
        _ = try session.split("c2", at: 96_000, rightID: "c3")
        try session.write(to: url)
        return url
    }

    /// The key-down of each new key, as a keyboard sends it.
    func event(_ command: TimelineCommand, in window: NSWindow) throws -> NSEvent {
        let (characters, plain, flags, code): (String, String, NSEvent.ModifierFlags, UInt16) =
            switch command {
            case .rollToPlayhead: ("X", "x", .shift, 7)
            case .slipLeft: ("\u{F702}", "\u{F702}", [.shift, .option, .numericPad, .function], 123)
            default: ("\u{F703}", "\u{F703}", [.shift, .option, .numericPad, .function], 124)
            }
        return try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: plain, isARepeat: false,
                keyCode: code))
    }

    static let keyed: [TimelineCommand] = [.rollToPlayhead, .slipLeft, .slipRight]

    /// With the focus in a track name field, the field gets Shift-X as "X" and the two arrow keys as a
    /// selection of the word before the caret, and a key makes no edit and no undo entry. Control: a
    /// case with `forwardsKey` false rolls and slips while the user types.
    @Test func aFocusedFieldGetsEachNewKey() async throws {
        let (model, studio, window, _) = try await openLanes(app, try await package())
        await studio.perform(.seek(.frame(60_000)))
        model.timeline.selection = .range(Marks(tracks: ["t1"]))
        let editor = try await focusName(in: window)
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        let (session, revision) = (studio.session, studio.sessionRevision)

        let text = editor.string
        app.timeline(.rollToPlayhead, event: try event(.rollToPlayhead, in: window), in: window)
        #expect(editor.string == text + "X", "the field got the capital letter")
        for command in [TimelineCommand.slipLeft, .slipRight] {
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            app.timeline(command, event: try event(command, in: window), in: window)
            let range = editor.selectedRange()
            if command == .slipLeft {
                #expect(range.length > 0, "Shift-Option-Left selected the word before the caret: \(range)")
            } else {
                #expect(range.length == 0, "Shift-Option-Right at the end of the text selects nothing: \(range)")
            }
        }

        #expect(studio.session == session && studio.sessionRevision == revision, "no key made an edit")
        #expect(Self.keyed.allSatisfy { $0.forwardsKey }, "each case forwards its key")
        await model.close()
    }

    /// With no field focused, each key runs its item.
    @Test func withNoFieldFocusedEachNewKeyReachesItsItem() async throws {
        let (model, studio, window, _) = try await openLanes(app, try await package())
        await studio.perform(.seek(.frame(60_000)))
        model.timeline.selection = .range(Marks(tracks: ["t1"]))

        app.timeline(.rollToPlayhead, event: try event(.rollToPlayhead, in: window), in: window)
        #expect(studio.session.clip("c1")?.clip.length == 60_000, "Shift-X rolled the join to the playhead")
        try studio.undo()

        model.timeline.selection = .clips(ClipSet("c2"))
        let offset = studio.session.clip("c2")?.clip.offset ?? 0
        app.timeline(.slipLeft, event: try event(.slipLeft, in: window), in: window)
        #expect(studio.session.clip("c2")?.clip.offset == offset + 480, "Shift-Option-Left slipped the content left")
        app.timeline(.slipRight, event: try event(.slipRight, in: window), in: window)
        #expect(studio.session.clip("c2")?.clip.offset == offset, "Shift-Option-Right slipped it back")
        await model.close()
    }

    /// The new items have their keys, and Close Gaps has none.
    @Test func theKeysAreTheRuledKeys() {
        let keys = Dictionary(
            uniqueKeysWithValues: TimelineCommand.editItems.map {
                ($0.command, KeyboardShortcut($0.key, modifiers: $0.modifiers))
            })
        #expect(keys[.rollToPlayhead] == KeyboardShortcut("x", modifiers: .shift))
        #expect(keys[.slipLeft] == KeyboardShortcut(.leftArrow, modifiers: [.shift, .option]))
        #expect(keys[.slipRight] == KeyboardShortcut(.rightArrow, modifiers: [.shift, .option]))
        #expect(keys[.closeGaps] == nil && TimelineCommand.keylessTitles[.closeGaps] == .menuEditCloseGaps)
    }

    /// The K1 method of decision 0025: an AppKit menu with the new keys takes Shift-X, Shift-Option-Left,
    /// and Shift-Option-Right. X and the arrows are on the same key on the US and the Spanish ISO
    /// layouts, so both layouts send the same chord.
    @Test func theNewKeysReachTheirItemsOnTheUSAndTheSpanishLayouts() {
        _ = NSApplication.shared
        final class Target: NSObject {
            var fired: [String] = []
            @objc func fire(_ item: NSMenuItem) { fired.append(item.title) }
        }
        let target = Target()
        let menu = NSMenu()
        for item in TimelineCommand.editItems where Self.keyed.contains(item.command) {
            let menuItem = NSMenuItem(
                title: "\(item.command)", action: #selector(Target.fire(_:)), keyEquivalent: String(item.key.character))
            menuItem.keyEquivalentModifierMask = NSEvent.ModifierFlags(item.modifiers)
            menuItem.target = target
            menu.addItem(menuItem)
        }
        func chord(_ characters: String, _ plain: String, _ flags: NSEvent.ModifierFlags, code: UInt16) -> NSEvent {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                characters: characters, charactersIgnoringModifiers: plain, isARepeat: false, keyCode: code)!
        }
        let arrows: NSEvent.ModifierFlags = [.shift, .option, .numericPad, .function]

        #expect(menu.performKeyEquivalent(with: chord("X", "x", .shift, code: 7)), "Shift-X")
        #expect(menu.performKeyEquivalent(with: chord("\u{F702}", "\u{F702}", arrows, code: 123)), "Shift-Option-Left")
        #expect(menu.performKeyEquivalent(with: chord("\u{F703}", "\u{F703}", arrows, code: 124)), "Shift-Option-Right")
        #expect(target.fired == ["rollToPlayhead", "slipLeft", "slipRight"], "\(target.fired)")
    }
}
