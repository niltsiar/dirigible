import AppKit
import DirigibleCore
import DirigibleTimeline
import Testing

@testable import DirigibleApp

/// The selection paths of the pane, the tint, and the clears of the pane selection (criteria P7,
/// P9).
extension TranscriptSelectionTests {
    /// An arrow key with `flags`: 123 Left, 124 Right.
    func arrow(_ code: UInt16, _ flags: NSEvent.ModifierFlags, in window: NSWindow) -> NSEvent {
        let text = String(
            Character(UnicodeScalar(UInt16(code == 123 ? NSLeftArrowFunctionKey : NSRightArrowFunctionKey))!))
        return NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags.union([.numericPad, .function]), timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text,
            isARepeat: false, keyCode: code)!
    }

    /// P9: a long cue of t2 in the middle of the selection ends after the last unit in text order,
    /// so the range ends at the end of the cue.
    @Test func rangeUsesTheLatestEnd() async throws {
        let (model, _, _, _, pane) = try await shown(guest: [(1.6, 9, "Long")])
        let text = try #require(pane.shown?.text)
        let order = text.units.map { (text.string as NSString).substring(with: NSRange($0.text)) }
        let (long, second) = (try #require(order.firstIndex(of: "Long")), try #require(order.firstIndex(of: "Second")))
        try #require(long < second, "Second is after the cue in text order")

        pane.setSelectedRange(try range("there", "Second", in: pane))

        #expect(model.timeline.selection == Self.range(72_000, 432_000), "from there at 1.5 s to the cue end at 9 s")
        await model.close()
    }

    /// P9: each selection path gives whole units in one range and writes the range: a drag, the
    /// Option-Shift and Shift-Command arrows, a Command-drag of two ranges, and an accessibility set.
    @Test func everySelectionPathSnaps() async throws {
        let (model, _, window, _, pane) = try await shown()
        let hello = try range("Hello", in: pane)
        let helloThere = try range("Hello", "there", in: pane)
        let second = try range("Second", in: pane)
        let inside = hello.location + 2
        func check(_ path: String, _ expected: NSRange, _ selection: Selection, _ select: () -> Void) {
            pane.setSelectedRange(NSRange(location: inside, length: 0))
            model.timeline.selection = .none
            select()
            #expect(pane.selectedRanges.count == 1, "\(path): one range")
            #expect(pane.selectedRange() == expected, "\(path): whole units")
            #expect(model.timeline.selection == selection, "\(path): the range")
        }

        check("drag", hello, Self.range(48_000, 72_000)) {
            pane.setSelectedRanges(
                [NSValue(range: NSRange(location: inside, length: 1))], affinity: .downstream, stillSelecting: true)
        }
        check("Option-Shift-Right", hello, Self.range(48_000, 72_000)) {
            pane.keyDown(with: arrow(124, [.option, .shift], in: window))
        }
        check("Shift-Command-Right", helloThere, Self.range(48_000, 96_000)) {
            pane.keyDown(with: arrow(124, [.command, .shift], in: window))
        }
        check("Command-drag", try range("Hello", "Second", in: pane), Self.range(48_000, 312_000)) {
            pane.setSelectedRanges(
                [NSRange(location: inside, length: 1), NSRange(location: second.location + 1, length: 1)].map(
                    NSValue.init),
                affinity: .downstream, stillSelecting: false)
        }
        check("accessibility", helloThere, Self.range(48_000, 96_000)) {
            pane.setAccessibilitySelectedTextRange(NSRange(location: inside, length: helloThere.length - 3))
        }
        await model.close()
    }

    /// P9: a range from the lanes tints the words and keeps the caret of the pane, and the pane
    /// writes no range of its own: the timeline range stays the lanes range.
    @Test func tintDoesNotSelect() async throws {
        let (model, _, window, _, pane) = try await shown()
        let caret = NSRange(location: try range("Second", in: pane).location, length: 0)
        pane.setSelectedRange(caret)
        let lanes = Selection.range(Marks(inPoint: 280_000, outPoint: 324_001, tracks: ["t1"]))

        model.timeline.selection = lanes
        await until(limit: .seconds(10), "the pane shows the lanes range") {
            settle(window)
            return pane.shownSelection == lanes
        }

        #expect(pane.selectedRange() == caret, "the tint does not select")
        #expect(model.timeline.selection == lanes, "the tint writes no range")
        #expect(tinted(pane) == [try range("Second", "part", in: pane)])
        await model.close()
    }

    /// P9: Deselect All clears the range that the pane wrote, so the pane selection and the tint go.
    @Test func clearedRangeClearsThePane() async throws {
        let (model, _, window, _, pane) = try await shown()
        let secondPart = try range("Second", "part", in: pane)
        pane.setSelectedRange(secondPart)
        try #require(model.timeline.selection == Self.range(288_000, 336_000))
        await until(limit: .seconds(10), "the pane range is tinted") {
            settle(window)
            return tinted(pane) == [secondPart]
        }

        model.run(.deselectAll)

        await until(limit: .seconds(10), "Deselect All clears the pane selection") {
            settle(window)
            return pane.selectedRange().length == 0
        }
        #expect(tinted(pane).isEmpty)
        #expect(model.timeline.selection == .none)
        await model.close()
    }

    /// P9: a new text (here a track rename) clears the pane selection, writes no range, and tints
    /// the range in the new text.
    @Test func replacementClearsThePaneSelection() async throws {
        let (model, studio, window, _, pane) = try await shown()
        pane.setSelectedRange(try range("Second", "part", in: pane))
        let selection = model.timeline.selection
        let replacements = pane.replacements

        try studio.edit(ripple: false) { session throws(SessionError) in
            try session.renameTrack("t1", to: "Hostess")
        }

        await until(limit: .seconds(10), "the new text replaces the storage") {
            settle(window)
            return pane.replacements > replacements && pane.shownRevision == pane.builtRevision
        }
        #expect(pane.selectedRange().length == 0, "the pane selection clears")
        #expect(model.timeline.selection == selection, "the reset writes no range")
        let secondPart = try range("Second", "part", in: pane)
        await until(limit: .seconds(10), "the tint shows the range in the new text") {
            settle(window)
            return tinted(pane) == [secondPart]
        }
        await model.close()
    }

    /// P7: a key move of the pane selection gives the word count to VoiceOver; a mouse selection and
    /// an accessibility set give none.
    @Test func selectionIsAnnounced() async throws {
        let (model, _, window, _, pane) = try await shown()
        let there = try range("there", in: pane)
        pane.setSelectedRanges([NSValue(range: there)], affinity: .downstream, stillSelecting: false)
        pane.setAccessibilitySelectedTextRange(there)
        #expect(pane.announced == nil, "no count for a mouse or accessibility selection")

        app.transport(.seek(.nextClip), event: shiftArrow(124, in: window), in: window)
        await model.settleTransport()
        #expect(pane.selectedRange() == (try range("there", "Second", in: pane)))
        #expect(pane.announced == 2, "Shift-Right: there and Second")

        pane.keyDown(with: shiftArrow(125, in: window))
        #expect(pane.selectedRange() == (try range("there", "part", in: pane)))
        #expect(pane.announced == 3, "Shift-Down: to the sentence end")
        await model.close()
    }
}
