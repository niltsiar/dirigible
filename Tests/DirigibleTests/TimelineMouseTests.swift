import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Mouse-edits criteria 2, 3, 7, 8, 9, and 9b in a real session window: the events go to the lanes
/// as `TimelineViewTests` sends them.
@Suite(.serialized) @MainActor struct TimelineMouseTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws { folder = try TemporaryFolder() }

    /// A session window with two tracks and a clip of 20 s from 0 on each (c1 on t1, c2 on t2).
    func open() async throws -> (SessionWindow, Studio, NSWindow, TimelineScrollView) {
        try await openLanes(app, try await timelinePackage(in: folder.url, tracks: 2, seconds: 20))
    }

    /// A point 40 pt into the upper part of the box of `clip`: the move zone.
    func body(_ clip: ClipID, in view: TimelineScrollView) throws -> NSPoint {
        let box = try #require(view.lanes.clipFrame(clip))
        return NSPoint(x: box.minX + 40, y: box.minY + 10)
    }

    /// Criterion 8, the lanes (plan gate 1 item 7): an Esc key-down from `CGEvent` goes from the
    /// first responder of the window (the lanes) to the gesture. It proves the routing only: a
    /// synthetic event cannot hold a real button (manual check M3). The window gets the event,
    /// not the application: the test process has no key window, and `NSApp.sendEvent` gave the
    /// key-down to the window of another suite that ran at the same time (decisions.tsv).
    @Test func escapeWithAGestureActiveReachesTheGesture() async throws {
        let (model, studio, window, view) = try await open()
        let start = try body("c1", in: view)
        view.lanes.mouseDown(with: try mouse(.leftMouseDown, start, in: view))
        view.lanes.mouseDragged(with: try mouse(.leftMouseDragged, NSPoint(x: start.x + 20, y: start.y), in: view))
        #expect(view.lanes.inputs?.session != studio.session, "the drag shows a preview")

        window.sendEvent(try cgKey(53))

        #expect(view.lanes.inputs?.session == studio.session, "Esc drops the preview")
        view.lanes.mouseUp(with: try mouse(.leftMouseUp, NSPoint(x: start.x + 20, y: start.y), in: view))
        #expect(studio.session.clip("c1")?.clip.start == 0 && !studio.canUndo, "the mouse-up after Esc commits")
        await model.close()
    }

    /// The lanes of `tracks` tracks at 512 frames per point and 100 pt lanes (`standaloneLanes`):
    /// c1 is x 0 to 1875 pt on lane 1, and its move zone is y 0 to 66.6 pt.
    func lanes(tracks: Int = 2) async throws -> (SessionWindow, Studio, NSWindow, TimelineScrollView) {
        let (model, studio) = try await timelineModel(
            try await timelinePackage(in: folder.url, tracks: tracks, seconds: 20), app: app)
        let (window, view) = standaloneLanes(model, studio)
        return (model, studio, window, view)
    }

    func press(_ view: TimelineScrollView, _ x: Double, _ y: Double) throws {
        view.lanes.mouseDown(with: try mouse(.leftMouseDown, NSPoint(x: x, y: y), in: view))
    }

    func drag(_ view: TimelineScrollView, _ x: Double, _ y: Double) throws {
        view.lanes.mouseDragged(with: try mouse(.leftMouseDragged, NSPoint(x: x, y: y), in: view))
    }

    func release(_ view: TimelineScrollView, _ x: Double, _ y: Double) throws {
        view.lanes.mouseUp(with: try mouse(.leftMouseUp, NSPoint(x: x, y: y), in: view))
    }

    /// Waits until the main-actor tasks that the events started ran: a seek of a stopped Studio
    /// sets the playhead with no suspension, and the main actor runs its tasks in order.
    func settle() async { await Task { @MainActor in }.value }

    /// Criterion 2: a click on the upper part of c1 selects its range on t1 and does not seek.
    @Test func aClickOnAClipSelectsItAndKeepsThePlayhead() async throws {
        let (model, studio, window, view) = try await lanes()
        await studio.perform(.seek(.frame(10_000)))

        try press(view, 100, 10)
        try release(view, 101, 10)
        await settle()

        #expect(model.timeline.marks == Marks(inPoint: 0, outPoint: 960_000, tracks: ["t1"]))
        #expect(studio.playhead == 10_000 && !studio.canUndo)
        window.close()
        await model.close()
    }

    /// Code gate 1 item 1: a click with 3 pt of jitter (0.5 pt right, 3 pt down) selects c1, and
    /// the session and the undo stack do not change.
    @Test func aClickWithJitterMovesNothing() async throws {
        let (model, studio, window, view) = try await lanes()
        let before = studio.session

        try press(view, 100, 10)
        try release(view, 100.5, 13)
        await settle()

        #expect(studio.session == before && !studio.canUndo)
        #expect(model.timeline.marks == Marks(inPoint: 0, outPoint: 960_000, tracks: ["t1"]))
        window.close()
        await model.close()
    }

    /// Criterion 3: during the drag the lanes draw c1 at 51,200 and the Studio keeps it at 0; the
    /// mouse-up makes one undo entry, the Marks take the new range, and the lanes draw the Studio
    /// session (gate 1 item 4).
    @Test func aDragMovesTheClipInOneUndoEntry() async throws {
        let (model, studio, window, view) = try await lanes()
        let before = studio.session

        try press(view, 100, 10)
        try drag(view, 150, 10)
        try drag(view, 200, 10)
        #expect(view.lanes.inputs?.session.clip("c1")?.clip.start == 51_200, "the preview")
        #expect(studio.session == before && !studio.canUndo)
        try release(view, 200, 10)

        let moved = try #require(studio.session.clip("c1"))
        #expect(moved.track == "t1" && moved.clip.range == 51_200..<1_011_200 && moved.clip.offset == 0)
        #expect(model.timeline.marks == Marks(inPoint: 51_200, outPoint: 1_011_200, tracks: ["t1"]))
        #expect(view.lanes.inputs?.session == studio.session, "the lanes draw the committed session")
        model.undo()
        #expect(studio.session == before && !studio.canUndo, "one undo entry")
        window.close()
        await model.close()
    }

    /// Criterion 7: a SwiftUI update with new peaks and the same session keeps the preview, and
    /// the mouse-up commits it.
    @Test func anUpdateDuringADragKeepsThePreview() async throws {
        let (model, studio, window, view) = try await lanes()
        try press(view, 100, 10)
        try drag(view, 200, 10)
        var inputs = laneInputs(model, studio)
        inputs.peaks = ["f1": .ready(randomPeaks(frames: 960_000))]

        view.update(inputs)

        #expect(view.lanes.inputs?.peaks == inputs.peaks, "the update reaches the lanes")
        #expect(view.lanes.inputs?.session.clip("c1")?.clip.start == 51_200, "the preview stays")
        try release(view, 200, 10)
        #expect(studio.session.clip("c1")?.clip.start == 51_200)
        window.close()
        await model.close()
    }

    /// Criterion 7, the `show` trap: a zoom during a drag reads the source, not the drawn preview,
    /// so the gesture goes on. After the zoom to 256 frames per point, x 400 is frame 102,400.
    @Test func aZoomDuringADragKeepsTheSource() async throws {
        let (model, studio, window, view) = try await lanes()
        let before = studio.session
        try press(view, 100, 10)
        try drag(view, 200, 10)

        view.zoom(by: 0.5, at: 0)

        #expect(view.framesPerPoint == 256)
        #expect(view.lanes.inputs?.session.clip("c1")?.clip.start == 51_200 && studio.session == before)
        try release(view, 400, 10)
        #expect(studio.session.clip("c1")?.clip.start == 51_200)
        model.undo()
        #expect(studio.session == before && !studio.canUndo, "one undo entry")
        window.close()
        await model.close()
    }

    /// Criterion 9: an undo after the last SwiftUI update and before the up drops the commit: no
    /// entry (the redo stays), no alert.
    @Test func anUndoDuringADragDropsTheCommit() async throws {
        let (model, studio, window, view) = try await lanes()
        let before = studio.session
        model.edit { s throws(SessionError) in try s.renameTrack("t2", to: "Guest") }
        try press(view, 100, 10)
        try drag(view, 200, 10)

        model.undo()
        try release(view, 200, 10)

        #expect(studio.session == before && studio.canRedo && model.alert == nil)
        #expect(view.lanes.inputs?.session == studio.session)
        window.close()
        await model.close()
    }

    /// Criterion 9, plan gate 2 item 3: an undo between two drag events. A drag event does not read
    /// the Studio, so the next SwiftUI update gives the gesture the change: the lanes draw the
    /// Studio session, and the up makes no entry.
    @Test func anUndoBetweenTwoDragEventsDropsTheGesture() async throws {
        let (model, studio, window, view) = try await lanes()
        let before = studio.session
        model.edit { s throws(SessionError) in try s.renameTrack("t2", to: "Guest") }
        try press(view, 100, 10)
        try drag(view, 150, 10)

        model.undo()
        try drag(view, 200, 10)
        view.update(laneInputs(model, studio))

        #expect(view.lanes.inputs?.session == studio.session)
        try release(view, 200, 10)
        #expect(studio.session == before && studio.canRedo && model.alert == nil)
        window.close()
        await model.close()
    }

    /// Criterion 9b, plan gate 1 item 2: a typed track name, then a drag. The mouse-down commits
    /// the name before the gesture starts, so the focus change of the field does not drop the drag.
    /// Two undo entries: the rename and the move.
    @Test func aRenameThenADragMakesTwoUndoEntries() async throws {
        let (model, studio, window, view) = try await open()
        let before = studio.session
        let editor = try await focusName(in: window)
        editor.insertText("Host", replacementRange: NSRange(location: NSNotFound, length: 0))
        await until("the name field has a draft") { model.drafts["t1"] != nil }
        let start = try body("c1", in: view)

        view.lanes.mouseDown(with: try mouse(.leftMouseDown, start, in: view))
        // The field ends its edit, and SwiftUI updates the lanes, as between two real events.
        await until("the lanes get the renamed session") {
            model.drafts.isEmpty && view.lanes.inputs?.session.track("t1")?.name == studio.session.track("t1")?.name
                && studio.session.track("t1")?.name != "T1"
        }
        view.lanes.mouseDragged(with: try mouse(.leftMouseDragged, NSPoint(x: start.x + 20, y: start.y), in: view))
        view.lanes.mouseUp(with: try mouse(.leftMouseUp, NSPoint(x: start.x + 20, y: start.y), in: view))

        let renamed = try #require(studio.session.track("t1")?.name)
        #expect(renamed != "T1" && studio.session.clip("c1")?.clip.start != 0, "the rename and the move")
        model.undo()
        #expect(studio.session.clip("c1")?.clip.start == 0 && studio.session.track("t1")?.name == renamed)
        model.undo()
        #expect(studio.session == before && !studio.canUndo, "two undo entries")
        await model.close()
    }

    /// Decision 0020, the dirty rect: a drag event redraws only the columns of the clips that it
    /// changes, at full height (a narrow rect). c1 is x 200 to 300 pt; a drag of 50 pt makes it 250
    /// to 350, so the event redraws x 200 to 350 with 1 pt on each side, not the 1440 pt in view.
    /// New Marks draw their columns; new peaks draw all. The trim comes before the lanes draw, so
    /// no partial draw comes before the event. The next event also covers the draw of the event
    /// before it (code gate 1 item 1 of the timeline-scroll run): x 199 to 361.
    @Test func aDragEventRedrawsOnlyTheClipsItChanges() async throws {
        let (model, studio) = try await timelineModel(
            try await timelinePackage(in: folder.url, tracks: 2, seconds: 20), app: app)
        try studio.edit { s throws(SessionError) in try s.trim("c1", to: 102_400..<153_600) }
        let (window, view) = standaloneLanes(model, studio)
        try press(view, 250, 10)

        try drag(view, 300, 10)
        drawNow(window)

        #expect(view.lanes.drawnRect == NSRect(x: 199, y: 0, width: 152, height: 200))
        try drag(view, 310, 10)
        drawNow(window)
        #expect(view.lanes.drawnRect == NSRect(x: 199, y: 0, width: 162, height: 200), "and the draw before")
        view.update(laneInputs(model, studio, marks: Marks(inPoint: 0, outPoint: 512_000, tracks: ["t2"])))
        drawNow(window)
        #expect(view.lanes.drawnRect == NSRect(x: 0, y: 0, width: 1002, height: 200), "new Marks: all rows")
        view.update(laneInputs(model, studio, marks: Marks(inPoint: 0, outPoint: 512_000, tracks: ["t8"])))
        drawNow(window)
        let draws = view.lanes.draws
        view.update(laneInputs(model, studio, marks: Marks(inPoint: 0, outPoint: 512_000, tracks: ["t9"])))
        drawNow(window)
        #expect(view.lanes.draws == draws, "Marks that draw the same pixels draw nothing")
        var inputs = laneInputs(model, studio, marks: Marks(inPoint: 0, outPoint: 512_000, tracks: ["t9"]))
        inputs.peaks = ["f1": .ready(randomPeaks(frames: 960_000))]
        view.update(inputs)
        drawNow(window)
        #expect(view.lanes.drawnRect.width > 1440, "new peaks draw the lanes, not only the changed clips")
        window.close()
        await model.close()
    }

    /// Code gate 1 item 1 of the timeline-scroll run: a partial draw also covers the partial draw
    /// before it. When that union is more than a quarter of the lanes in view larger than the new
    /// rect, the event draws all lanes once, and the next event draws only its own columns again.
    /// c1 is x 200 to 300. New Marks of x 400 to 800 draw x 399 to 802 at full height. The union
    /// with the first event is x 199 to 802: under half the lanes in view, but a triangle drag with
    /// such Marks drew them again at each event. The first event draws all lanes, the next only
    /// x 249 to 361.
    @Test func aDragAfterAnEditFarAwayDrawsTheLanesOnce() async throws {
        let (model, studio) = try await timelineModel(
            try await timelinePackage(in: folder.url, tracks: 2, seconds: 20), app: app)
        try studio.edit { s throws(SessionError) in try s.trim("c1", to: 102_400..<153_600) }
        let (window, view) = standaloneLanes(model, studio)
        view.update(laneInputs(model, studio, marks: Marks(inPoint: 204_800, outPoint: 409_600, tracks: ["t1", "t2"])))
        drawNow(window)
        #expect(view.lanes.drawnRect == NSRect(x: 399, y: 0, width: 403, height: 200), "the Marks")
        try press(view, 250, 10)

        try drag(view, 300, 10)
        drawNow(window)
        #expect(view.lanes.drawnRect == view.lanes.bounds, "all lanes")
        try drag(view, 310, 10)
        drawNow(window)
        #expect(view.lanes.drawnRect == NSRect(x: 249, y: 0, width: 112, height: 200), "only the event")

        try release(view, 310, 10)
        window.close()
        await model.close()
    }

    /// Code gate 2 item 2 of the timeline-scroll run: the union limit counts only the lanes in view.
    /// 8 lanes of 100 pt, 376 pt in view: new Marks of x 400 to 600 draw x 399 to 602 on all
    /// lanes, and the first event of a drag of c1 (x 200 to 300) draws x 199 to 351. In view the
    /// union adds 251 x 376 pt, under a quarter of the view (1440 x 94 pt), so the event draws the
    /// union. With the rows out of view it added 251 x 800 pt, and the event drew all lanes.
    @Test func theUnionLimitCountsOnlyTheLanesInView() async throws {
        let (model, studio) = try await timelineModel(
            try await timelinePackage(in: folder.url, tracks: 8, seconds: 20), app: app)
        try studio.edit { s throws(SessionError) in try s.trim("c1", to: 102_400..<153_600) }
        let (window, view) = standaloneLanes(model, studio)
        try #require(view.shown.minY == 0 && view.shown.height == 376, "\(view.shown)")
        let all = Set((1...8).map { TrackID("t\($0)") })
        view.update(laneInputs(model, studio, marks: Marks(inPoint: 204_800, outPoint: 307_200, tracks: all)))
        drawNow(window)
        #expect(view.lanes.drawnRect == NSRect(x: 399, y: 0, width: 203, height: 376), "the Marks")
        try press(view, 250, 10)

        try drag(view, 300, 10)
        drawNow(window)

        #expect(view.lanes.drawnRect == NSRect(x: 199, y: 0, width: 403, height: 376), "the union, not all lanes")
        try release(view, 300, 10)
        window.close()
        await model.close()
    }

    /// Code gate 1 item 2: a drag of a clip wider than the view redraws the rows of its lanes only.
    /// c1 is x 0 to 1875 pt on lane 1 of 3; a drag to lane 2 redraws the rows of lanes 1 and 2.
    @Test func aWideClipDragRedrawsOnlyTheRowsOfItsLanes() async throws {
        let (model, _, window, view) = try await lanes(tracks: 3)
        try press(view, 100, 10)

        try drag(view, 150, 10)
        drawNow(window)
        #expect(view.lanes.drawnRect.minY == 0 && view.lanes.drawnRect.height == 100, "lane 1")
        try drag(view, 150, 110)
        drawNow(window)
        #expect(view.lanes.drawnRect.minY == 0 && view.lanes.drawnRect.height == 200, "lanes 1 and 2")

        try release(view, 100, 10)
        window.close()
        await model.close()
    }

    /// Code gate 1 item 2: during a move of the last clip past the session end, the lanes keep
    /// their width, so the event redraws only the columns of the clip (AppKit draws the new columns
    /// of a wider view, and the draw joins them). The part past the lanes is never in view: the lanes
    /// are at least as wide as the view. The mouse-up gives the new width. c1 is x 1800 to 1875 pt,
    /// the end of the session; the lanes in view end at the end of the lanes (1912.5 pt).
    @Test func aDragPastTheEndKeepsTheWidthUntilTheUp() async throws {
        let (model, studio) = try await timelineModel(
            try await timelinePackage(in: folder.url, tracks: 2, seconds: 20), app: app)
        try studio.edit { s throws(SessionError) in
            try s.trim("c1", to: 921_600..<960_000)
            try s.trim("c2", to: 0..<102_400)
        }
        let (window, view) = standaloneLanes(model, studio)
        view.scroll(toFrame: 472.5 * 512)
        drawNow(window)
        let width = view.lanes.frame.width
        try press(view, 1830, 10)

        try drag(view, 1880, 10)
        drawNow(window)

        #expect(view.lanes.frame.width == width, "the same width during the drag")
        #expect(view.lanes.drawnRect == NSRect(x: 1799, y: 0, width: 113.5, height: 200), "not the new columns")
        try release(view, 1880, 10)
        #expect(view.lanes.frame.width == width + 50 * 1.02, "the new width at the up")
        window.close()
        await model.close()
    }

    /// Phase 7 of the mouse-edits run: a new width redraws the lanes in view. With the redraw
    /// policy `onSetNeedsDisplay`, AppKit drew only the new columns, and on screen the old columns
    /// showed the old pixels scaled to the new width (a strip of stripes at the left after a move
    /// past the session end). At 2048 frames per point the lanes are as wide as the view (1440 pt);
    /// a view 160 pt wider makes them 1600 pt wide.
    @Test func aNewWidthRedrawsTheLanesInView() async throws {
        let (model, studio, window, view) = try await lanes()
        var inputs = laneInputs(model, studio)
        inputs.scale = TimelineScale(framesPerPoint: 2048)
        view.update(inputs)
        drawNow(window)
        #expect(view.lanes.frame.width == 1440)
        let draws = view.lanes.draws

        window.setContentSize(NSSize(width: window.frame.width + 160, height: window.frame.height))
        view.frame = try #require(window.contentView).bounds
        drawNow(window)

        #expect(view.lanes.frame.width == 1600)
        #expect(view.lanes.draws == draws + 1, "one draw")
        #expect(view.lanes.drawnRect.minX == 0 && view.lanes.drawnRect.width >= 1600, "\(view.lanes.drawnRect)")
        window.close()
        await model.close()
    }

    /// Criterion 6: c1 is x 200 to 300 pt, frames 102,400 to 153,600 of f1 (960,000 frames). One
    /// drag event takes its end to the end of f1, and one takes its start to the start of f1. Each
    /// trim is one undo entry, with no alert.
    @Test func anEdgeDragTrimsWithinItsLimits() async throws {
        let (model, studio, window, view) = try await lanes()
        try studio.edit { s throws(SessionError) in try s.trim("c1", to: 102_400..<153_600) }
        view.update(laneInputs(model, studio))
        let trimmed = studio.session

        try press(view, 298, 10)
        try drag(view, 2000, 10)
        #expect(view.lanes.inputs?.session.clip("c1")?.clip.range == 102_400..<960_000, "the preview")
        #expect(studio.session == trimmed)
        try release(view, 2000, 10)
        #expect(studio.session.clip("c1")?.clip.range == 102_400..<960_000 && model.alert == nil)
        #expect(model.timeline.marks == Marks(inPoint: 102_400, outPoint: 960_000, tracks: ["t1"]))

        try press(view, 202, 10)
        try drag(view, 0, 10)
        try release(view, 0, 10)
        let clip = try #require(studio.session.clip("c1")?.clip)
        #expect(clip.range == 0..<960_000 && clip.offset == 0 && model.alert == nil)
        model.undo()
        #expect(studio.session.clip("c1")?.clip.range == 102_400..<960_000)
        model.undo()
        #expect(studio.session == trimmed, "one undo entry for each trim")
        window.close()
        await model.close()
    }

    /// Criterion 10: a Shift-drag from the move zone of c1 extends the Marks and moves nothing.
    @Test func aShiftDragOnAClipExtendsAndMovesNothing() async throws {
        let (model, studio, window, view) = try await lanes()
        let before = studio.session
        model.timeline.marks = Marks(inPoint: 0, outPoint: 51_200, tracks: ["t2"])

        view.lanes.mouseDown(with: try mouse(.leftMouseDown, NSPoint(x: 200, y: 10), in: view, flags: .shift))
        view.lanes.mouseDragged(with: try mouse(.leftMouseDragged, NSPoint(x: 300, y: 10), in: view, flags: .shift))
        #expect(view.lanes.inputs?.session == before, "no preview")
        view.lanes.mouseUp(with: try mouse(.leftMouseUp, NSPoint(x: 300, y: 10), in: view, flags: .shift))

        #expect(model.timeline.marks == Marks(inPoint: 0, outPoint: 153_600, tracks: ["t1", "t2"]))
        #expect(studio.session == before && !studio.canUndo)
        window.close()
        await model.close()
    }
}
