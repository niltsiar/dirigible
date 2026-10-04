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

    /// The cursor kinds of the ripple trim (row 12:03).
    @Test func theRippleCursorPointsAwayFromTheClip() {
        #expect(NSCursor.timeline(.rippleTrim(.start)) == .resizeLeft)
        #expect(NSCursor.timeline(.rippleTrim(.end)) == .resizeRight)
    }
}
