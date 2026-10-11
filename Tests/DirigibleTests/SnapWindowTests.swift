import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
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
}
