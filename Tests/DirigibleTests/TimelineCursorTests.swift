import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp

/// The ripple cursor of the lanes (decision 0037, criterion C12, plan gate 1 item 5): c1 is x 0
/// to 1875 pt on lane 1, so x 2 is the trim zone of its start edge.
@Suite(.serialized) @MainActor struct TimelineCursorTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws { folder = try TemporaryFolder() }

    func lanes() async throws -> (SessionWindow, NSWindow, TimelineScrollView) {
        let (model, studio) = try await timelineModel(
            try await timelinePackage(in: folder.url, tracks: 2, seconds: 20), app: app)
        let (window, view) = standaloneLanes(model, studio)
        return (model, window, view)
    }

    func flagsChanged(_ flags: NSEvent.ModifierFlags, in window: NSWindow) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: 58))
    }

    /// `flagsChanged` reaches only the first responder, so the hover path reads the flags through
    /// the seam. Control: a hover that reads no flags gives resizeLeftRight.
    @Test func aMouseMoveReadsTheModifierFlags() async throws {
        let (model, window, view) = try await lanes()
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        window.contentView?.addSubview(field)
        #expect(window.makeFirstResponder(field), "a text field has the focus")
        view.lanes.modifierFlags = { .option }
        view.lanes.mouseMoved(with: try mouse(.mouseMoved, NSPoint(x: 2, y: 10), in: view))
        #expect(view.lanes.shownCursor == .rippleTrim(.start))
        view.lanes.modifierFlags = { [] }
        view.lanes.mouseMoved(with: try mouse(.mouseMoved, NSPoint(x: 2, y: 10), in: view))
        #expect(view.lanes.shownCursor == .resizeLeftRight)
        await model.close()
    }

    /// An Option key-down or key-up over a trim zone sets the cursor again with no mouse move.
    /// Control: no cursor change at a flags change.
    @Test func anOptionChangeSetsTheCursorAgain() async throws {
        let (model, window, view) = try await lanes()
        view.lanes.modifierFlags = { [] }
        view.lanes.mouseMoved(with: try mouse(.mouseMoved, NSPoint(x: 2, y: 10), in: view))
        #expect(view.lanes.shownCursor == .resizeLeftRight)
        view.lanes.flagsChanged(with: try flagsChanged(.option, in: window))
        #expect(view.lanes.shownCursor == .rippleTrim(.start), "Option goes down")
        view.lanes.flagsChanged(with: try flagsChanged([], in: window))
        #expect(view.lanes.shownCursor == .resizeLeftRight, "Option goes up")
        await model.close()
    }

    /// C25: a flags change to Shift-Command sets the slip cursor over the upper part of a clip with
    /// no mouse move, and a flags change to no keys sets the arrow again. Control: a `flagsChanged`
    /// that passes Option only keeps the arrow.
    @Test func theShiftCommandKeysSetTheSlipCursor() async throws {
        let (model, window, view) = try await lanes()
        view.lanes.modifierFlags = { [] }
        view.lanes.mouseMoved(with: try mouse(.mouseMoved, NSPoint(x: 500, y: 30), in: view))
        #expect(view.lanes.shownCursor == .arrow, "no keys")
        view.lanes.flagsChanged(with: try flagsChanged([.shift, .command], in: window))
        #expect(view.lanes.shownCursor == .openHand, "Shift and Command go down")
        view.lanes.flagsChanged(with: try flagsChanged([], in: window))
        #expect(view.lanes.shownCursor == .arrow, "the keys go up")
        view.lanes.flagsChanged(with: try flagsChanged([.shift, .command, .option], in: window))
        #expect(view.lanes.shownCursor == .arrow, "Option makes it no roll or slip")
        await model.close()
    }

    /// C25: with a text field focused, `flagsChanged` does not arrive, so a mouse move reads Shift
    /// and Command through the seam. Control: a hover that reads Option only gives the arrow.
    @Test func aMouseMoveReadsShiftCommand() async throws {
        let (model, window, view) = try await lanes()
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        window.contentView?.addSubview(field)
        #expect(window.makeFirstResponder(field), "a text field has the focus")
        view.lanes.modifierFlags = { [.shift, .command] }
        view.lanes.mouseMoved(with: try mouse(.mouseMoved, NSPoint(x: 500, y: 30), in: view))
        #expect(view.lanes.shownCursor == .openHand)
        view.lanes.mouseMoved(with: try mouse(.mouseMoved, NSPoint(x: 2, y: 10), in: view))
        #expect(view.lanes.shownCursor == .resizeLeftRight, "the start zone rolls or trims")
        view.lanes.modifierFlags = { [] }
        view.lanes.mouseMoved(with: try mouse(.mouseMoved, NSPoint(x: 500, y: 30), in: view))
        #expect(view.lanes.shownCursor == .arrow)
        await model.close()
    }

    /// C29: the help tag of the lanes names the Shift-Command drag. Control: lanes with no tag.
    @Test func theHelpTagNamesTheShiftCommandDrag() async throws {
        let (model, _, view) = try await lanes()
        #expect(view.lanes.toolTip == L10n.timelineHelpRollSlip.text)
        #expect(try stringsTable("en")["timeline.help.roll.slip"]?.contains("Shift-Command") == true)
        // The help tag adds a tracking area of its own: the area of the mouse moves stays.
        view.lanes.updateTrackingAreas()
        #expect(view.lanes.trackingAreas.contains { $0.owner === view.lanes && $0.options.contains(.mouseMoved) })
        await model.close()
    }

    /// The cursor kinds of the ripple trim (row 12:03).
    @Test func theRippleCursorPointsAwayFromTheClip() {
        #expect(NSCursor.timeline(.rippleTrim(.start)) == .resizeLeft)
        #expect(NSCursor.timeline(.rippleTrim(.end)) == .resizeRight)
    }
}
