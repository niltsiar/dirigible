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
        try studio.edit { s throws(SessionError) in
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
