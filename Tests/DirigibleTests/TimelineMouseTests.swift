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

    /// Criterion 2: a click on the upper part of c1 selects it as a clip set and does not seek.
    @Test func aClickOnAClipSelectsItAndKeepsThePlayhead() async throws {
        let (model, studio, window, view) = try await lanes()
        await studio.perform(.seek(.frame(10_000)))

        try press(view, 100, 10)
        try release(view, 101, 10)
        await settle()

        #expect(model.timeline.selection == .clips(ClipSet("c1")))
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
        #expect(model.timeline.selection == .clips(ClipSet("c1")))
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
        #expect(model.timeline.selection == .clips(ClipSet("c1")))
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

    /// Criterion 7, the `show` trap: a zoom during a drag must not commit the drawn preview, and the
    /// gesture goes on. Decision 0025: a lane gesture holds the scale, so the zoom does nothing, and
    /// the release at x 300 moves the clip 200 pt at 512 frames per point.
    @Test func aZoomDuringADragKeepsTheSource() async throws {
        let (model, studio, window, view) = try await lanes()
        let before = studio.session
        try press(view, 100, 10)
        try drag(view, 200, 10)

        view.navigate(.zoom(by: 0.5, at: 0))

        #expect(view.framesPerPoint == 512, "a lane gesture holds the scale")
        #expect(view.lanes.inputs?.session.clip("c1")?.clip.start == 51_200 && studio.session == before)
        try release(view, 300, 10)
        #expect(studio.session.clip("c1")?.clip.start == 102_400)
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
        model.edit(ripple: false) { s throws(SessionError) in try s.renameTrack("t2", to: "Guest") }
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
        model.edit(ripple: false) { s throws(SessionError) in try s.renameTrack("t2", to: "Guest") }
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

    /// Criterion 6: c1 is x 200 to 300 pt, frames 102,400 to 153,600 of f1 (960,000 frames). One
    /// drag event takes its end to the end of f1, and one takes its start to the start of f1. Each
    /// trim is one undo entry, with no alert.
    @Test func anEdgeDragTrimsWithinItsLimits() async throws {
        let (model, studio, window, view) = try await lanes()
        try studio.edit(ripple: false) { s throws(SessionError) in try s.trim("c1", to: 102_400..<153_600) }
        view.update(laneInputs(model, studio))
        let trimmed = studio.session

        try press(view, 298, 10)
        try drag(view, 2000, 10)
        #expect(view.lanes.inputs?.session.clip("c1")?.clip.range == 102_400..<960_000, "the preview")
        #expect(studio.session == trimmed)
        try release(view, 2000, 10)
        #expect(studio.session.clip("c1")?.clip.range == 102_400..<960_000 && model.alert == nil)
        #expect(model.timeline.selection == .clips(ClipSet("c1")))

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

    /// A Shift-drag from the move zone of c1 draws a marquee (decision 0038): no clip lies whole in
    /// it, so the selection goes, the Marks stay, and nothing moves.
    @Test func aShiftDragOnAClipDrawsAMarqueeAndMovesNothing() async throws {
        let (model, studio, window, view) = try await lanes()
        let before = studio.session
        let marks = Marks(inPoint: 0, outPoint: 51_200, tracks: ["t2"])
        model.timeline.marks = marks

        view.lanes.mouseDown(with: try mouse(.leftMouseDown, NSPoint(x: 200, y: 10), in: view, flags: .shift))
        view.lanes.mouseDragged(with: try mouse(.leftMouseDragged, NSPoint(x: 300, y: 10), in: view, flags: .shift))
        #expect(view.lanes.inputs?.session == before, "no preview")
        view.lanes.mouseUp(with: try mouse(.leftMouseUp, NSPoint(x: 300, y: 10), in: view, flags: .shift))

        #expect(model.timeline.selection == .none)
        #expect(studio.session == before && !studio.canUndo)
        window.close()
        await model.close()
    }

    /// C11: the marquee layer shows the rectangle from the press to the pointer at each drag event,
    /// and hides at the up and at Esc.
    @Test func theMarqueeLayerFollowsTheDragAndHides() async throws {
        let (model, _, window, view) = try await lanes()
        let layer = view.lanes.marquee
        #expect(layer.isHidden)

        view.lanes.mouseDown(with: try mouse(.leftMouseDown, NSPoint(x: 200, y: 10), in: view, flags: .shift))
        #expect(layer.isHidden, "a press is no marquee")
        view.lanes.mouseDragged(with: try mouse(.leftMouseDragged, NSPoint(x: 300, y: 60), in: view, flags: .shift))
        #expect(!layer.isHidden && layer.frame == CGRect(x: 200, y: 10, width: 100, height: 50))
        view.lanes.mouseDragged(with: try mouse(.leftMouseDragged, NSPoint(x: 150, y: 130), in: view, flags: .shift))
        #expect(layer.frame == CGRect(x: 150, y: 10, width: 50, height: 120), "left of the press, on lane 2")
        view.lanes.mouseUp(with: try mouse(.leftMouseUp, NSPoint(x: 150, y: 130), in: view, flags: .shift))
        #expect(layer.isHidden)

        view.lanes.mouseDown(with: try mouse(.leftMouseDown, NSPoint(x: 200, y: 10), in: view, flags: .shift))
        view.lanes.mouseDragged(with: try mouse(.leftMouseDragged, NSPoint(x: 300, y: 60), in: view, flags: .shift))
        #expect(view.cancelGesture())
        #expect(layer.isHidden, "Esc drops the marquee")
        view.lanes.mouseUp(with: try mouse(.leftMouseUp, NSPoint(x: 300, y: 60), in: view, flags: .shift))
        window.close()
        await model.close()
    }

    /// The tester steps of run 2026-10-15-split-no-cut: t1 has a cut at 480,000 (x 937.5 pt). A
    /// click on the right part of t1, a ruler click at the cut (a seek to it), and a click on c2
    /// select c2 with the playhead inside it. Split then cuts c2 at the playhead.
    @Test func splitAfterAClickOnAClipCutsTheClipAtThePlayhead() async throws {
        let (model, studio, window, view) = try await lanes()
        try studio.edit(ripple: false) { s throws(SessionError) in _ = try s.splitClips(at: [480_000], on: ["t1"]) }
        try press(view, 1000, 10)
        try release(view, 1000, 10)
        try #require(model.timeline.selection == .clips(ClipSet("c1@480000")))
        view.ruler.mouseDown(with: try rulerMouse(.leftMouseDown, 937.5, 20, in: view))
        view.ruler.mouseUp(with: try rulerMouse(.leftMouseUp, 937.5, 20, in: view))
        await settle()
        try #require(studio.playhead == 480_000)
        try press(view, 600, 110)
        try release(view, 600, 110)
        try #require(model.timeline.selection == .clips(ClipSet("c2")))

        model.run(.split)

        #expect(studio.session.track("t2")?.clips.map(\.id) == ["c2", "c2@480000"])
        window.close()
        await model.close()
    }
}
