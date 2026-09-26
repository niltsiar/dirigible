import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Mouse-edits criteria 8, 11, and 13 on the time ruler of a real session window: the events go
/// to the ruler as the lanes get theirs.
@Suite(.serialized) @MainActor struct TimelineRulerTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws { folder = try TemporaryFolder() }

    static let flag = Marker(id: "m1", name: "Intro", position: 102_400, kind: .marker)

    /// The lanes of two tracks at 512 frames per point (`standaloneLanes`) with marker m1 at
    /// 102,400 (x 200 pt). The playhead is at the end of the session (960,000).
    func lanes() async throws -> (SessionWindow, Studio, NSWindow, TimelineScrollView) {
        let (model, studio) = try await timelineModel(
            try await timelinePackage(in: folder.url, tracks: 2, seconds: 20), app: app)
        try studio.edit { s throws(SessionError) in try s.setMarker(Self.flag) }
        let (window, view) = standaloneLanes(model, studio)
        return (model, studio, window, view)
    }

    func press(_ view: TimelineScrollView, _ x: Double, _ y: Double = 10) throws {
        view.ruler.mouseDown(with: try rulerMouse(.leftMouseDown, x, y, in: view))
    }

    func drag(_ view: TimelineScrollView, _ x: Double, _ y: Double = 10) throws {
        view.ruler.mouseDragged(with: try rulerMouse(.leftMouseDragged, x, y, in: view))
    }

    func release(_ view: TimelineScrollView, _ x: Double, _ y: Double = 10) throws {
        view.ruler.mouseUp(with: try rulerMouse(.leftMouseUp, x, y, in: view))
    }

    /// Criterion 8, the ruler (plan gate 2 item 1): with a track name field focused, a ruler
    /// mouse-down makes the lanes the first responder, so Esc ends the flag drag, not the edit of
    /// the field. It proves the routing only (manual check M3).
    @Test func escapeDuringAFlagDragWithAFocusedFieldReachesTheGesture() async throws {
        let (model, studio, window, view) = try await openLanes(
            app, try await timelinePackage(in: folder.url, tracks: 2, seconds: 20))
        model.edit { s throws(SessionError) in try s.setMarker(Self.flag) }
        await until("the ruler shows the flag") { view.ruler.inputs?.markers["m1"] != nil }
        let x = try #require(view.ruler.inputs?.geometry.x(of: Self.flag.position))
        _ = try await focusName(in: window)

        try press(view, x + 1)
        try drag(view, x + 21)
        #expect(view.lanes.inputs?.session.markers["m1"]?.position != Self.flag.position, "the preview")

        window.sendEvent(try cgKey(53))

        #expect(view.lanes.inputs?.session == studio.session, "Esc drops the preview")
        try release(view, x + 21)
        #expect(studio.session.markers["m1"] == Self.flag, "the mouse-up after Esc commits nothing")
        model.undo()
        #expect(studio.session.markers.isEmpty && !studio.canUndo, "only the entry of the marker")
        await model.close()
    }

    /// Criterion 11: a drag of the flag by 50 pt moves m1 to 128,000 in one undo entry, makes it
    /// the current marker, and does not seek.
    @Test func aFlagDragMovesTheMarkerInOneUndoEntry() async throws {
        let (model, studio, window, view) = try await lanes()
        let before = studio.session

        try press(view, 201)
        try drag(view, 226)
        try drag(view, 251)
        #expect(view.ruler.inputs?.markers["m1"]?.position == 128_000, "the preview")
        #expect(studio.session == before)
        try release(view, 251)
        await Task { @MainActor in }.value

        #expect(studio.session.markers["m1"]?.position == 128_000 && model.timeline.marker == "m1")
        #expect(studio.playhead == 960_000, "no seek")
        model.undo()
        #expect(studio.session == before)
        window.close()
        await model.close()
    }

    /// Criterion 11: a click on a flag makes it the current marker and seeks to it.
    @Test func aFlagClickMakesItTheCurrentMarkerAndSeeks() async throws {
        let (model, studio, window, view) = try await lanes()

        try press(view, 201)
        try release(view, 202)

        #expect(model.timeline.marker == "m1")
        await until("the flag click seeks") { studio.playhead == 102_400 }
        #expect(studio.session.markers["m1"] == Self.flag, "a click edits nothing")
        window.close()
        await model.close()
    }

    /// The ruler menu at the document x `x`.
    func menu(_ view: TimelineScrollView, _ x: Double) throws -> NSMenu? {
        view.ruler.menu(for: try rulerMouse(.rightMouseDown, x, 10, in: view))
    }

    /// Criterion 13: Add Marker and Add Chapter at the clicked frame, not at the playhead; Delete
    /// Marker only on a flag. Each item is one undo entry.
    @Test func theRulerMenuAddsAtTheClickAndDeletesTheFlag() async throws {
        let (model, studio, window, view) = try await lanes()
        let before = studio.session

        let empty = try #require(try menu(view, 400))
        #expect(
            empty.items.map(\.title) == [
                L10n.menuMarkersAdd.text, L10n.menuMarkersAddChapter.text, L10n.menuMarkersDelete.text,
            ])
        #expect(empty.items.map(\.isEnabled) == [true, true, false])
        empty.performActionForItem(at: 0)
        let added = try #require(studio.session.markers.values.first { $0.id != "m1" })
        #expect(added.position == 204_800 && added.kind == .marker && model.timeline.marker == added.id)
        try #require(try menu(view, 600)).performActionForItem(at: 1)
        #expect(studio.session.markers.values.contains { $0.kind == .chapter && $0.position == 307_200 })

        let onFlag = try #require(try menu(view, 201))
        #expect(onFlag.items[2].isEnabled)
        onFlag.performActionForItem(at: 2)
        #expect(studio.session.markers["m1"] == nil && studio.session.markers.count == 2)

        model.undo()
        model.undo()
        model.undo()
        #expect(studio.session == before, "one undo entry for each item")
        window.close()
        await model.close()
    }

    /// Criterion 13, Q10 of the analysis: no menu during a gesture; the drag goes on.
    @Test func noRulerMenuDuringADrag() async throws {
        let (model, studio, window, view) = try await lanes()
        try press(view, 201)
        try drag(view, 251)

        #expect(try menu(view, 400) == nil)

        try release(view, 251)
        #expect(studio.session.markers["m1"]?.position == 128_000, "the drag went on")
        #expect(try menu(view, 400) != nil)
        window.close()
        await model.close()
    }

    /// Decision 0020, the dirty rect of a flag drag: m1 goes from x 200 to 250 pt, so the event
    /// redraws x 200 to 251 with 1 pt on each side, not the 1440 pt in view.
    @Test func aFlagDragEventRedrawsOnlyTheMarkerColumns() async throws {
        let (model, _, window, view) = try await lanes()
        try press(view, 201)

        try drag(view, 251)
        drawNow(window)

        #expect(view.lanes.drawnRect == NSRect(x: 199, y: 0, width: 53, height: 200))
        try release(view, 251)
        window.close()
        await model.close()
    }
}
