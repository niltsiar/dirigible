import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import SwiftUI
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The View and Edit commands of the timeline (decision 0017, criteria 17 and 18) in a real session
/// window. The tests send the action along the responder chain from the first responder, the
/// path of a menu item in a key window (P12).
@Suite(.serialized) @MainActor struct TimelineKeyTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws { folder = try TemporaryFolder() }

    /// A window with two tracks and a clip of 60 s on each, after SwiftUI shows the lanes.
    func open() async throws -> (SessionWindow, Studio, NSWindow, TimelineScrollView) {
        try await openLanes(app, try await timelinePackage(in: folder.url, tracks: 2, seconds: 60))
    }

    @Test func selectAllWithNoFieldFocusedSelectsTheSession() async throws {
        let (model, studio, window, view) = try await open()
        #expect(window.makeFirstResponder(view.lanes))

        #expect(window.firstResponder?.tryToPerform(#selector(NSResponder.selectAll(_:)), with: nil) == true)

        #expect(model.timeline.marks == Marks.all(in: studio.session))
        #expect(model.timeline.marks.tracks.count == 2)
        await model.close()
    }

    @Test func selectAllInANameFieldSelectsTheText() async throws {
        let (model, _, window, _) = try await open()
        let editor = try await focusName(in: window)
        editor.setSelectedRange(NSRange(location: 0, length: 0))

        #expect(window.firstResponder?.tryToPerform(#selector(NSResponder.selectAll(_:)), with: nil) == true)

        #expect(editor.selectedRange() == NSRange(location: 0, length: (editor.string as NSString).length))
        #expect(model.timeline.marks == Marks())
        await model.close()
    }

    @Test func escapeWithNoFieldFocusedEmptiesTheMarks() async throws {
        let (model, _, window, view) = try await open()
        model.timeline.marks = Marks(inPoint: 0, outPoint: 1000, tracks: ["t1"])
        #expect(window.makeFirstResponder(view.lanes))

        #expect(window.firstResponder?.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: nil) == true)

        #expect(model.timeline.marks == Marks())
        await model.close()
    }

    @Test func escapeInANameFieldLeavesTheMarks() async throws {
        let (model, _, window, _) = try await open()
        let marks = Marks(inPoint: 0, outPoint: 1000, tracks: ["t1"])
        model.timeline.marks = marks
        _ = try await focusName(in: window)

        _ = window.firstResponder?.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: nil)

        #expect(model.timeline.marks == marks)
        await model.close()
    }

    /// K3: a plain key of a menu item goes to the focused text field.
    @Test func aPlainIInANameFieldTypesI() async throws {
        let (model, _, window, _) = try await open()
        let editor = try await focusName(in: window)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        let before = editor.string

        app.timeline(.setIn, event: key(.keyDown, "i", code: 34, in: window), in: window)

        #expect(editor.string == before + "i")
        #expect(model.timeline.marks == Marks())
        await model.close()
    }

    @Test func aPlainIWithTheTimelineFocusedSetsTheInPoint() async throws {
        let (model, studio, window, view) = try await open()
        await studio.perform(.seek(.frame(48_000)))
        #expect(window.makeFirstResponder(view.lanes))

        app.timeline(.setIn, event: key(.keyDown, "i", code: 34, in: window), in: window)
        await studio.perform(.seek(.frame(96_000)))
        app.timeline(.setOut, event: key(.keyDown, "o", code: 31, in: window), in: window)

        #expect(model.timeline.marks == Marks(inPoint: 48_000, outPoint: 96_000, tracks: ["t1", "t2"]))
        await model.close()
    }

    /// Zoom In and Zoom Out keep the playhead at its x; the scale halves and doubles.
    @Test func zoomInAndOutKeepThePlayheadX() async throws {
        let (model, studio, _, view) = try await open()
        await studio.perform(.seek(.frame(480_000)))
        let points = view.framesPerPoint
        let x = (480_000 - view.origin) / points

        model.run(.zoomIn)
        #expect(view.framesPerPoint == points / 2)
        #expect(abs((480_000 - view.origin) / view.framesPerPoint - x) <= 1, "zoom in")
        model.run(.zoomOut)
        #expect(view.framesPerPoint == points)
        #expect(abs((480_000 - view.origin) / view.framesPerPoint - x) <= 1, "zoom out")
        #expect(model.timeline.scale.framesPerPoint == points)
        await model.close()
    }

    @Test func zoomToSelectionShowsTheSelection() async throws {
        let (model, _, _, view) = try await open()
        model.timeline.marks = Marks(inPoint: 480_000, outPoint: 960_000, tracks: ["t1"])

        model.run(.zoomToSelection)

        #expect(abs(view.origin - 456_000) <= view.framesPerPoint)
        #expect(abs(view.visibleFrames - 528_000) <= view.framesPerPoint)
        await model.close()
    }

    /// Automatic Scroll: off, then on again; on ends a hold and shows the playhead.
    @Test func automaticScrollTogglesTheFollow() async throws {
        let (model, studio, _, view) = try await open()
        model.run(.zoomIn)
        model.run(.zoomIn)
        await studio.perform(.seek(.frame(2_500_000)))

        model.run(.toggleFollow)
        #expect(!model.timeline.follows)
        model.timeline.followHeld = true
        view.scroll(toFrame: 0)
        model.run(.toggleFollow)

        #expect(model.timeline.follows && !model.timeline.followHeld)
        #expect(view.origin <= 2_500_000 && 2_500_000 < view.origin + view.visibleFrames, "the playhead shows")
        await model.close()
    }

    /// U1 (N11b): Command-= zooms in as Command-plus does; the Spanish Shift-Command-0 gives "="
    /// with Shift and does not zoom. The key events go to the window.
    @Test func commandEqualsZoomsIn() async throws {
        let (model, _, window, view) = try await open()
        let points = view.framesPerPoint
        func equals(_ flags: NSEvent.ModifierFlags, code: UInt16) -> NSEvent {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: "=", charactersIgnoringModifiers: "=", isARepeat: false, keyCode: code)!
        }

        #expect(window.performKeyEquivalent(with: equals([.command, .shift], code: 29)) == false)
        #expect(view.framesPerPoint == points, "Shift with = does not zoom")
        #expect(window.performKeyEquivalent(with: equals(.command, code: 24)))
        #expect(view.framesPerPoint == points / 2, "Command-= zooms in")
        await model.close()
    }

    /// U6: the View menu has a separator between its groups: the menu is built from these groups.
    @Test func theViewMenuHasItsGroups() {
        #expect(
            TimelineCommand.viewGroups.map { $0.map(\.command) } == [
                [.zoomIn, .zoomOut, .zoomToSession, .zoomToSelection], [.zoomBack, .zoomForward],
                [.pagePrevious, .pageNext],
                [.tallerTracks, .shorterTracks], [.toggleFollow],
            ])
        #expect(TimelineCommand.viewItems.map(\.command) == TimelineCommand.viewGroups.flatMap { $0 }.map(\.command))
    }

    /// F16: each new command has a menu item with its key. The menus are built from this table.
    /// The items of decision 0018 after them are in `EditKeyTests`.
    @Test func everyNewMenuItemHasItsKey() {
        let items = TimelineCommand.viewItems + TimelineCommand.editItems.prefix(3)
        let keys = items.map { "\($0.command) \($0.key.character) \($0.modifiers.rawValue)" }

        #expect(
            keys == [
                "zoomIn + \(EventModifiers.command.rawValue)", "zoomOut - \(EventModifiers.command.rawValue)",
                "zoomToSession 0 \(EventModifiers.command.rawValue)", "zoomToSelection h 0",
                "zoomBack \u{F702} \(EventModifiers([.command, .option]).rawValue)",
                "zoomForward \u{F703} \(EventModifiers([.command, .option]).rawValue)",
                "pagePrevious \u{F72C} \(EventModifiers.option.rawValue)",
                "pageNext \u{F72D} \(EventModifiers.option.rawValue)",
                "tallerTracks \u{F701} \(EventModifiers.command.rawValue)",
                "shorterTracks \u{F700} \(EventModifiers.command.rawValue)",
                "toggleFollow f \(EventModifiers([.command, .option]).rawValue)", "setIn i 0", "setOut o 0",
                "deselectAll a \(EventModifiers([.command, .shift]).rawValue)",
            ])
        #expect(Set(items.map(\.title)).count == items.count)
    }
}
