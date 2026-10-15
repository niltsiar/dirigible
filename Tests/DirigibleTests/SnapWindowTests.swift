import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import SwiftUI
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Snap run criteria C7 to C9 in a window: the lanes at 512 frames per point and 100 pt lanes
/// (`standaloneLanes`). c1 is x 0 to 1875 pt on lane 0 (move zone y 0 to 66 pt), and the playhead
/// is at x 300 (frame 153,600). A drag from x 100 to x 397 puts the start of c1 3 pt from the
/// playhead, so it snaps to x 300.
@Suite(.serialized) @MainActor struct SnapWindowTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)
    static let target = Frames(153_600)
    static let raw = Frames(297 * 512)

    init() throws { folder = try TemporaryFolder() }

    func lanes() async throws -> (SessionWindow, Studio, NSWindow, TimelineScrollView) {
        let (model, studio) = try await timelineModel(
            try await timelinePackage(in: folder.url, tracks: 2, seconds: 20), app: app)
        let (window, view) = standaloneLanes(model, studio)
        await studio.perform(.seek(.frame(Self.target)))
        await Task { @MainActor in }.value
        return (model, studio, window, view)
    }

    func event(_ type: NSEvent.EventType, _ x: Double, in view: TimelineScrollView, _ flags: NSEvent.ModifierFlags = [])
        throws
    {
        let made = try mouse(type, NSPoint(x: x, y: 10), in: view, flags: flags)
        switch type {
        case .leftMouseDown: view.lanes.mouseDown(with: made)
        case .leftMouseDragged: view.lanes.mouseDragged(with: made)
        default: view.lanes.mouseUp(with: made)
        }
    }

    func flags(_ flags: NSEvent.ModifierFlags, in view: TimelineScrollView, _ window: NSWindow) throws {
        view.lanes.flagsChanged(
            with: try #require(
                NSEvent.keyEvent(
                    with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                    isARepeat: false, keyCode: 55)))
    }

    func start(_ view: TimelineScrollView) -> Frames? { view.lanes.inputs?.session.clip("c1")?.clip.start }

    /// C7 (b) and (c): Command at a drag event, and a Command key change with no mouse move.
    @Test func commandDuringADragTurnsSnapOff() async throws {
        let (model, studio, window, view) = try await lanes()
        try event(.leftMouseDown, 100, in: view)
        try event(.leftMouseDragged, 397, in: view)
        #expect(start(view) == Self.target)
        try event(.leftMouseDragged, 397, in: view, .command)
        #expect(start(view) == Self.raw, "Command held at a drag event")
        try event(.leftMouseDragged, 397, in: view)
        #expect(start(view) == Self.target)
        try flags(.command, in: view, window)
        #expect(start(view) == Self.raw && view.lanes.guide.isHidden, "a Command key-down with no mouse move")
        try flags([], in: view, window)
        #expect(start(view) == Self.target && !view.lanes.guide.isHidden, "a Command key-up")
        try event(.leftMouseUp, 397, in: view)
        #expect(studio.session.clip("c1")?.clip.start == Self.target && view.lanes.guide.isHidden)
        await model.close()
    }

    /// C7 (a): the preference off gives the raw position in every window of the app.
    @Test func thePreferenceOffGivesTheRawPosition() async throws {
        let (model, _, _, view) = try await lanes()
        app.snaps = false
        try event(.leftMouseDown, 100, in: view)
        try event(.leftMouseDragged, 397, in: view)
        #expect(start(view) == Self.raw && view.lanes.guide.isHidden)
        try event(.leftMouseUp, 397, in: view)
        await model.close()
    }

    /// C7 (d), plan gate 1: Command at the mouse-down on a clip is a range drag; it does not snap
    /// while Command is held and snaps after a Command release.
    @Test func aCommandRangeDragSnapsAfterRelease() async throws {
        let (model, _, _, view) = try await lanes()
        // The pointer end at x 302 is 2 pt from the playhead.
        try event(.leftMouseDown, 100, in: view, .command)
        try event(.leftMouseDragged, 302, in: view, .command)
        #expect(model.timeline.selection.marks?.outPoint == Frames(302 * 512) && start(view) == 0)
        try event(.leftMouseDragged, 302, in: view)
        #expect(model.timeline.selection.marks?.outPoint == Self.target)
        try event(.leftMouseUp, 302, in: view)
        await model.close()
    }

    /// C8: the guide is a layer over the lanes. A Command change at a start that is on the target
    /// with no shift hides it and renders no lane rect.
    @Test func theGuideIsALayerWithNoLaneDraw() async throws {
        let (model, _, window, view) = try await lanes()
        try event(.leftMouseDown, 100, in: view)
        try event(.leftMouseDragged, 400, in: view)
        drawNow(window)
        #expect(start(view) == Self.target)
        let guide = view.lanes.guide
        #expect(!guide.isHidden && guide.position.x == 300 && guide.bounds.width == 1)
        #expect(guide.bounds.height == view.lanes.bounds.height && guide.zPosition > view.lanes.playhead.zPosition)
        let draws = view.lanes.draws
        try flags(.command, in: view, window)
        drawNow(window)
        #expect(guide.isHidden && start(view) == Self.target, "the start stays, the guide goes")
        #expect(view.lanes.draws == draws, "no lane render")
        view.lanes.increasesContrast = true
        try flags([], in: view, window)
        #expect(guide.bounds.width == 2, "Increase Contrast")
        try event(.leftMouseUp, 400, in: view)
        await model.close()
    }

    /// Plan gate item 3: N during a drag sends the drag again, so the clip and the guide take the
    /// new state with no mouse move.
    @Test func nDuringADragResendsTheDrag() async throws {
        // The fixture window is not a session window, so the key path is nil (nTogglesSnapAndTypesInAField).
        let (model, _, _, view) = try await lanes()
        model.timelineView = view
        app.key = model
        try event(.leftMouseDown, 100, in: view)
        try event(.leftMouseDragged, 397, in: view)
        #expect(start(view) == Self.target)
        app.toggleSnap(event: nil, in: nil)
        #expect(!app.snaps && start(view) == Self.raw && view.lanes.guide.isHidden, "snap off at once")
        app.toggleSnap(event: nil, in: nil)
        #expect(app.snaps && start(view) == Self.target && !view.lanes.guide.isHidden, "snap on at once")
        try event(.leftMouseUp, 397, in: view)
        await model.close()
    }

    /// Code gate item 3: a new target 8 pt away plays the haptic again. A snapped drag event renders
    /// the lanes once, and none when the clip stays on its target (the snap benches are not in the
    /// push check).
    @Test func aNewTargetPlaysTheHapticAndEachSnappedEventDrawsOnce() async throws {
        let (model, studio, window, view) = try await lanes()
        let marker = Frames(308 * 512)
        try studio.edit(ripple: false) { s throws(SessionError) in
            try s.setMarker(Marker(id: "m", name: "M", position: marker, kind: .marker))
        }
        view.update(laneInputs(model, studio))
        drawNow(window)
        var plays = 0
        view.lanes.guide.feedback = { plays += 1 }
        try event(.leftMouseDown, 100, in: view)
        for (x, expected, count, renders) in [(397.0, Self.target, 1, 1), (405, marker, 2, 1), (406, marker, 2, 0)] {
            let draws = view.lanes.draws
            try event(.leftMouseDragged, x, in: view)
            drawNow(window)
            #expect(start(view) == expected && plays == count, "x \(x)")
            #expect(view.lanes.draws == draws + renders, "x \(x): \(renders) render")
        }
        try event(.leftMouseUp, 406, in: view)
        await model.close()
    }

    /// C9: the haptic plays once at each change from not snapped to snapped.
    @Test func theHapticPlaysOncePerSnap() async throws {
        let (model, _, _, view) = try await lanes()
        var plays = 0
        view.lanes.guide.feedback = { plays += 1 }
        try event(.leftMouseDown, 100, in: view)
        for x in [397.0, 398, 399] { try event(.leftMouseDragged, x, in: view) }
        #expect(plays == 1)
        try event(.leftMouseDragged, 420, in: view)
        try event(.leftMouseDragged, 397, in: view)
        #expect(plays == 2, "off the target and on again")
        try event(.leftMouseUp, 397, in: view)
        app.snaps = false
        try event(.leftMouseDown, 100, in: view)
        try event(.leftMouseDragged, 397, in: view)
        #expect(plays == 2, "snap off")
        try event(.leftMouseUp, 397, in: view)
        await model.close()
    }
}

/// Snap run C10: the app preference.
@MainActor struct SnapPreferenceTests {
    let name = "SnapPreferenceTests-\(UUID().uuidString)"

    @Test func snapIsOnWithNoStoredValueAndAToggleIsKept() throws {
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let app = AppDelegate(recordings: nil, defaults: defaults)
        #expect(app.snaps && defaults.object(forKey: "timeline.snaps") == nil)
        app.snaps = false
        #expect(defaults.object(forKey: "timeline.snaps") as? Bool == false)
        #expect(AppDelegate(recordings: nil, defaults: defaults).snaps == false, "a new launch reads it")
        #expect(AppDelegate(recordings: nil).snaps, "no defaults: on")
    }

    /// Plan gate item 1: the menu item, its N key, and the toolbar item reach the one writer, and
    /// the toolbar item shows the state.
    @Test func oneWriterForEachEntryPoint() async throws {
        let folder = try TemporaryFolder()
        let app = AppDelegate(recordings: nil)
        let (model, _) = try await timelineModel(
            try await timelinePackage(in: folder.url, tracks: 1, seconds: 1), app: app)
        app.key = model
        #expect(ChromeState(model: model).on.contains(.snap) && ChromeState(model: model).enabled.contains(.snap))
        app.toggleSnap(event: nil, in: nil)
        #expect(!app.snaps && !model.snaps && !ChromeState(model: model).on.contains(.snap), "the menu path")
        model.leafCalls = []
        model.run(.toggleSnap)
        #expect(app.snaps && model.leafCalls == ["toggleSnap"], "the toolbar path")
        #expect(ToolbarItemID.snap.command == .toggleSnap && WindowCommand.toggleSnap.menuItem.title == .menuViewSnap)
        #expect(WindowCommand.toggleSnap.menuItem.key == KeyboardShortcut("n", modifiers: []))
        #expect(toolbarTooltip(.toggleSnap, format: "%@ (%@)") == "menu.view.snap (N)")
        await model.close()
    }

    /// Plan gate item 1: N goes to a focused text field first, as the transport keys. Control:
    /// with no text focus, N toggles snap.
    @Test(arguments: [true, false])
    func nTogglesSnapAndTypesInAField(focus: Bool) throws {
        let app = AppDelegate(recordings: nil)
        let window = UndoRoutingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered,
            defer: false)
        let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 200, height: 24))
        window.contentView?.addSubview(field)
        #expect(window.makeFirstResponder(focus ? field : nil))
        app.toggleSnap(event: key(.keyDown, "n", code: 45, in: window), in: window)
        #expect(field.stringValue == (focus ? "n" : ""))
        #expect(app.snaps == focus)
    }

    /// Code gate item 1: a held N toggles once; the key repeats do nothing.
    @Test func aHeldNTogglesOnce() throws {
        let app = AppDelegate(recordings: nil)
        let window = UndoRoutingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered,
            defer: false)
        app.toggleSnap(event: key(.keyDown, "n", code: 45, in: window), in: window)
        for _ in 0..<3 { app.toggleSnap(event: key(.keyDown, "n", code: 45, repeat: true, in: window), in: window) }
        #expect(!app.snaps)
    }
}
