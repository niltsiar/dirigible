import AppKit
import DirigibleCore
import DirigibleTimeline
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Timeline-navigation criterion N16: autoscroll during a drag, driven by `autoscrollTick` at 60
/// ticks a second. The lanes of `standaloneLanes`: 2 tracks of a 20 s clip at 512 frames per
/// point, 1440 pt of lanes after the 340 pt headers; the lanes are 1913 pt wide, so the last
/// origin is 473 pt.
@Suite(.serialized) @MainActor struct AutoscrollTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws { folder = try TemporaryFolder() }

    func lanes() async throws -> (SessionWindow, Studio, NSWindow, TimelineScrollView) {
        let (model, studio) = try await timelineModel(
            try await timelinePackage(in: folder.url, tracks: 2, seconds: 20), app: app)
        let (window, view) = standaloneLanes(model, studio)
        view.viewWillMove(toWindow: nil)
        return (model, studio, window, view)
    }

    /// `ticks` ticks at 60 Hz from `start` seconds.
    func ticks(_ view: TimelineScrollView, _ count: Int, from start: Double = 100) {
        for n in 0..<count { view.autoscrollTick(at: start + Double(n) / 60) }
    }

    @Test func aStillPointerPastTheEdgeScrollsAndTheClipFollows() async throws {
        let (model, studio, window, view) = try await lanes()
        view.lanes.mouseDown(with: try mouse(.leftMouseDown, NSPoint(x: 100, y: 10), in: view))
        let edge = Double(view.shown.maxX)
        view.lanes.mouseDragged(with: try mouse(.leftMouseDragged, NSPoint(x: edge + 40, y: 10), in: view))
        let start = try #require(view.lanes.inputs?.session.clip("c1")?.clip.start)
        ticks(view, 10)
        let moved = view.origin / 512
        #expect(moved > 100, "the clip follows a still pointer: the lanes scrolled \(moved) pt")
        let follows = try #require(view.lanes.inputs?.session.clip("c1")?.clip.start)
        #expect(abs(Double((follows - start).count) - view.origin) <= 1024, "the clip follows a still pointer")
        view.lanes.mouseUp(with: try mouse(.leftMouseUp, NSPoint(x: edge + 40 + moved, y: 10), in: view))
        let stopped = view.origin
        ticks(view, 10, from: 200)
        #expect(view.origin == stopped, "the mouse-up stops the scroll")
        #expect(studio.canUndo)
        window.close()
        await model.close()
    }

    /// Code gate 2 item 2: a frame with a real drag event and a tick shows the preview at the
    /// pointer after the scroll, so the mouse-up at the same window point drops the clip where the
    /// last frame showed it.
    @Test func theDropAtTheMouseUpIsThePreviewOfTheLastFrame() async throws {
        let (model, studio, window, view) = try await lanes()
        view.lanes.mouseDown(with: try mouse(.leftMouseDown, NSPoint(x: 100, y: 10), in: view))
        let drag = try mouse(.leftMouseDragged, NSPoint(x: Double(view.shown.maxX) + 40, y: 10), in: view)
        view.lanes.mouseDragged(with: drag)
        view.autoscrollTick(at: 100)
        view.lanes.mouseDragged(with: drag)
        view.autoscrollTick(at: 100 + 1.0 / 60)
        #expect(view.origin > 0, "the ticks scroll")
        let preview = try #require(view.lanes.inputs?.session.clip("c1")?.clip.start)
        let up = view.lanes.convert(drag.locationInWindow, from: nil)
        view.lanes.mouseUp(with: try mouse(.leftMouseUp, up, in: view))
        let dropped = try #require(studio.session.clip("c1")?.clip.start)
        #expect(dropped == preview, "the drop at the mouse-up is the preview of the last frame")
        window.close()
        await model.close()
    }

    /// The frames of `MouseEventBenchmark.anAutoscrollTickFitsOneFrame`: a drag event 40 or 41 pt
    /// past the right edge, then a tick and the draw. Each frame makes a new preview, scrolls, and
    /// draws the lanes once, for c1 trimmed to x 100 to 200 pt and for c2 (1875 pt, wider than the
    /// view).
    @Test func eachAutoscrollFrameDrawsTheLanesOnce() async throws {
        let (model, studio, window, view) = try await lanes()
        try studio.edit(ripple: false) { s throws(SessionError) in try s.trim("c1", to: 51_200..<102_400) }
        view.update(laneInputs(model, studio))
        drawNow(window)
        for (start, name, down) in [
            (100.0, "clip", NSPoint(x: 130, y: 10)), (200, "wide clip", NSPoint(x: 30, y: 110)),
        ] {
            view.scroll(toFrame: 0)
            drawNow(window)
            view.lanes.mouseDown(with: try mouse(.leftMouseDown, down, in: view))
            let drags = try [40.0, 41].map {
                try mouse(.leftMouseDragged, NSPoint(x: Double(view.shown.maxX) + $0, y: down.y), in: view)
            }
            view.lanes.mouseDragged(with: drags[0])
            drawNow(window)
            for frame in 1...5 {
                let (origin, draws, before) = (view.origin, view.lanes.draws, view.lanes.inputs)
                view.lanes.mouseDragged(with: drags[frame % 2])
                let moved = view.lanes.inputs != before
                view.autoscrollTick(at: start + Double(frame) / 60)
                drawNow(window)

                #expect(moved, "\(name) frame \(frame) made no new preview")
                #expect(view.origin > origin, "\(name) frame \(frame) did not scroll")
                let drew = view.lanes.draws - draws
                #expect(drew == 1, "\(name) frame \(frame) drew \(drew) times")
            }
            #expect(view.cancelGesture(), "Esc ends the drag")
        }
        window.close()
        await model.close()
    }

    @Test func insideTheLanesNothingScrolls() async throws {
        let (model, _, window, view) = try await lanes()
        view.lanes.mouseDown(with: try mouse(.leftMouseDown, NSPoint(x: 100, y: 10), in: view))
        view.lanes.mouseDragged(with: try mouse(.leftMouseDragged, NSPoint(x: 1300, y: 10), in: view))
        ticks(view, 10)
        #expect(view.origin == 0)
        _ = view.cancelGesture()
        window.close()
        await model.close()
    }

    /// The ramp: 40 pt outside is 800 pt/s, and after 1 s 1600 pt/s. The held width stops it.
    @Test func theScrollStopsAtTheHeldWidth() async throws {
        let (model, _, window, view) = try await lanes()
        view.lanes.mouseDown(with: try mouse(.leftMouseDown, NSPoint(x: 100, y: 10), in: view))
        let width = view.lanes.frame.width
        view.lanes.mouseDragged(
            with: try mouse(.leftMouseDragged, NSPoint(x: Double(view.shown.maxX) + 40, y: 10), in: view))
        ticks(view, 120)
        #expect(view.lanes.frame.width == width, "the lanes keep their width")
        #expect(abs(Double(view.shown.maxX) - Double(width)) <= 0.5, "the scroll stops at the held width")
        #expect(view.cancelGesture(), "Esc ends the drag")
        let stopped = view.origin
        ticks(view, 10, from: 300)
        #expect(view.origin == stopped, "Esc stops the scroll")
        window.close()
        await model.close()
    }

    /// The 340 pt headers are left of the lanes: a pointer over them is past the leading edge.
    @Test func aPointerOverTheHeadersScrollsLeft() async throws {
        let (model, _, window, view) = try await lanes()
        view.scroll(toFrame: 300 * 512)
        view.lanes.mouseDown(
            with: try mouse(.leftMouseDown, NSPoint(x: Double(view.shown.minX) + 700, y: 80), in: view))
        view.lanes.mouseDragged(
            with: try mouse(.leftMouseDragged, NSPoint(x: Double(view.shown.minX) - 40, y: 80), in: view))
        ticks(view, 10)
        #expect(view.origin < 300 * 512, "a pointer over the headers scrolls left: \(view.origin / 512)")
        _ = view.cancelGesture()
        window.close()
        await model.close()
    }

    /// A range drag and a flag drag on the ruler scroll too; during play autoscroll holds the follow.
    @Test func aRangeAndAFlagDragScroll() async throws {
        let (model, studio, window, view) = try await lanes()
        view.lanes.mouseDown(with: try mouse(.leftMouseDown, NSPoint(x: 100, y: 80), in: view))
        view.lanes.mouseDragged(
            with: try mouse(.leftMouseDragged, NSPoint(x: Double(view.shown.maxX) + 40, y: 80), in: view))
        studio.play.playback = .playing(Shuttle(direction: .forward, rate: .one))
        ticks(view, 10)
        #expect(view.origin > 0, "a range drag scrolls")
        #expect(model.timeline.followHeld, "an autoscroll during play holds the follow")
        studio.play.playback = .stopped
        view.lanes.mouseUp(with: try mouse(.leftMouseUp, NSPoint(x: Double(view.shown.maxX) + 40, y: 80), in: view))

        view.scroll(toFrame: 0)
        try studio.edit(ripple: false) { s throws(SessionError) in
            try s.setMarker(Marker(id: "m", name: "M", position: 51_200, kind: .marker))
        }
        view.update(laneInputs(model, studio))
        view.ruler.mouseDown(with: try rulerMouse(.leftMouseDown, 100, 4, in: view))
        view.ruler.mouseDragged(with: try rulerMouse(.leftMouseDragged, Double(view.shown.maxX) + 40, 4, in: view))
        ticks(view, 10, from: 200)
        #expect(view.origin > 0, "a flag drag scrolls")
        _ = view.cancelGesture()
        window.close()
        await model.close()
    }
}
