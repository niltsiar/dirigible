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

    /// The lanes of a session window, through SwiftUI, with m1 on the ruler, and the x of m1.
    func openedLanes() async throws -> (SessionWindow, Studio, TimelineScrollView, Double) {
        let (model, studio, _, view) = try await openLanes(
            app, try await timelinePackage(in: folder.url, tracks: 2, seconds: 20))
        model.edit { s throws(SessionError) in try s.setMarker(Self.flag) }
        await until("the ruler shows the flag") { view.ruler.inputs?.markers["m1"] != nil }
        return (model, studio, view, try #require(view.ruler.inputs?.geometry.x(of: Self.flag.position)))
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
        let (model, studio, view, x) = try await openedLanes()
        let window = try #require(view.window)
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

    /// The lanes scrolled so that the document x 300 is at the left edge of the lanes in view: m1
    /// (x 200) and the in point (x 100) are under the track headers.
    func scrolledLanes() async throws -> (SessionWindow, Studio, NSWindow, TimelineScrollView) {
        let (model, studio, window, view) = try await lanes()
        view.update(laneInputs(model, studio, marks: Marks(inPoint: 51_200)))
        view.scroll(toFrame: 153_600)
        drawNow(window)
        try #require(view.shown.minX == 300, "\(view.shown)")
        return (model, studio, window, view)
    }

    /// The pixels of the ruler, left of the x of `shown.minX`: the part over the track headers.
    func headerPart(of view: TimelineScrollView) throws -> [NSColor?] {
        let ruler = view.ruler
        let left = ruler.convert(NSPoint(x: view.shown.minX, y: 0), from: view.lanes).x
        let bitmap = try #require(ruler.bitmapImageRepForCachingDisplay(in: ruler.bounds))
        ruler.cacheDisplay(in: ruler.bounds, to: bitmap)
        let scale = Double(bitmap.pixelsWide) / ruler.bounds.width
        return (0..<Int(left * scale)).flatMap { x in (0..<bitmap.pixelsHigh).map { bitmap.colorAt(x: x, y: $0) } }
    }

    /// Timeline-scroll criterion 6: the time ruler is as wide as the window, also over the track
    /// headers. After a scroll, the ticks, labels, flags, and triangles of the times under the
    /// headers drew there, so the track seemed to go under the headers. The part over the headers
    /// keeps the pixels that it has at scroll 0, where no time is left of the lanes.
    @Test func theRulerDrawsNothingOverTheHeaders() async throws {
        let (model, studio, window, view) = try await lanes()
        view.update(laneInputs(model, studio, marks: Marks(inPoint: 51_200)))
        drawNow(window)
        let empty = try headerPart(of: view)
        try #require(empty.count > 1000, "the ruler part over the headers")

        view.scroll(toFrame: 153_600)
        drawNow(window)
        let part = try headerPart(of: view)

        #expect(view.shown.minX == 300, "m1 and the in point are under the headers: \(view.shown)")
        #expect(part.count == empty.count)
        #expect(zip(part, empty).allSatisfy { $0 == $1 }, "a tick, a label, a flag, or a triangle over the headers")
        window.close()
        await model.close()
    }

    /// The user report of timeline-scroll Q5: on screen, a horizontal scroll shows nothing of the
    /// time ruler over the track headers. AppKit scrolls the ruler by a copy of its pixels, so the
    /// ticks and labels over the lanes moved over the headers. `cacheDisplay` draws the ruler anew,
    /// so the test above cannot see it: this test reads captures of the window.
    @Test func aScrollOnScreenShowsNoTimeOverTheHeaders() async throws {
        let (model, studio) = try await timelineModel(
            try await timelinePackage(in: folder.url, tracks: 2, seconds: 600), app: app)
        let (window, view) = standaloneLanes(model, studio, onScreen: true)
        let ruler = view.ruler
        let left = ruler.convert(NSPoint(x: view.shown.minX, y: 0), from: view.lanes).x
        let corner = ruler.convert(NSRect(x: 0, y: 0, width: left, height: ruler.bounds.height), to: nil)
        let times = ruler.convert(
            NSRect(x: left, y: 0, width: ruler.bounds.width - left, height: ruler.bounds.height), to: nil)
        // The window server shows a flushed frame some milliseconds later; no signal tells when. So
        // each capture must also show new times over the lanes: a capture of the old frame fails.
        try await Task.sleep(for: .milliseconds(200))
        var image = try await TimelineColorTests.capture(window)
        let before = try Self.pixels(of: corner, image, window)
        var shownTimes = try Self.pixels(of: times, image, window)

        var changed: [String] = []
        for x in [720, 1333.37, 2100.5] {
            view.scroll(toFrame: x * 512)
            drawNow(window)
            try await Task.sleep(for: .milliseconds(200))
            image = try await TimelineColorTests.capture(window)
            let newTimes = try Self.pixels(of: times, image, window)
            #expect(newTimes != shownTimes, "the capture after the scroll to \(x) pt shows new times")
            shownTimes = newTimes
            let after = try Self.pixels(of: corner, image, window)
            let count = zip(before, after).filter { $0 != $1 }.count
            if count > 0 { changed.append("\(count) at \(x) pt") }
        }

        #expect(view.shown.minX == 2100.5, "the times of 0 to 2100.5 pt are under the headers: \(view.shown)")
        try #require(before.count > 1000, "the ruler part over the headers")
        #expect(changed.isEmpty, "pixels of the ruler over the headers changed after a scroll: \(changed)")
        window.close()
        await model.close()
    }

    /// The BGRA pixels of a capture of `window` in `rect` (window points).
    static func pixels(of rect: NSRect, _ image: CGImage, _ window: NSWindow) throws -> [UInt32] {
        let data = try #require(image.dataProvider?.data)
        let bytes = try #require(CFDataGetBytePtr(data))
        let scale = Double(image.width) / window.frame.width
        // The capture has row 0 at the top of the window; the window has y 0 at the bottom.
        let rows = Int((window.frame.height - rect.maxY) * scale)..<Int((window.frame.height - rect.minY) * scale)
        let columns = Int(rect.minX * scale)..<Int(rect.maxX * scale)
        return rows.flatMap { y in
            columns.map { x in UnsafeRawPointer(bytes + y * image.bytesPerRow + x * 4).loadUnaligned(as: UInt32.self) }
        }
    }

    /// Timeline-scroll criterion 7: a press on the ruler over the track headers does nothing: no
    /// seek, no flag drag, no menu. The marks, the markers, and the playhead stay.
    @Test func aRulerPressOverTheHeadersDoesNothing() async throws {
        let (model, studio, window, view) = try await scrolledLanes()
        let (session, marks) = (studio.session, model.timeline.marks)

        try press(view, 250)
        try release(view, 250)
        try press(view, 201)
        try drag(view, 260)
        try release(view, 260)
        await Task { @MainActor in }.value

        #expect(studio.playhead == 960_000, "no seek")
        #expect(studio.session == session && model.timeline.marks == marks)
        model.undo()
        #expect(studio.session.markers.isEmpty && !studio.canUndo, "only the undo entry of the fixture marker")
        #expect(view.ruler.menu(for: try rulerMouse(.rightMouseDown, 250, 10, in: view)) == nil, "no menu")
        window.close()
        await model.close()
    }

    /// Timeline-scroll criterion 7: a flag drag that goes over the track headers goes on, and the
    /// release there moves the marker to frame 0 (the gesture clamps it).
    @Test func aFlagDragOverTheHeadersGoesOn() async throws {
        let (model, studio, window, view) = try await lanes()

        try press(view, 201)
        try drag(view, 100)
        try drag(view, -100)
        try release(view, -100)
        await Task { @MainActor in }.value

        #expect(studio.session.markers["m1"]?.position == 0)
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
