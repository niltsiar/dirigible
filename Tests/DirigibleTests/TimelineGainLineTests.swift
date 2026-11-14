import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Criteria L4 to L7 of run 11b-1 in a real session window, as `TimelineMouseTests` sends the
/// events. c1 is trimmed to 102,400 ..< 153,600: x 200 to 300 pt on lane 0 at 512 frames per point
/// and 100 pt lanes. At 0 dB its gain band is y 0 to 6, and its fade-in handle is x 200 to 208,
/// y 0 to 8.
@Suite(.serialized) @MainActor struct TimelineGainLineTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws { folder = try TemporaryFolder() }

    func lanes(_ edit: (inout Session) throws(SessionError) -> Void = { _ throws(SessionError) in })
        async throws -> (SessionWindow, Studio, NSWindow, TimelineScrollView)
    {
        let (model, studio) = try await timelineModel(
            try await timelinePackage(in: folder.url, tracks: 2, seconds: 20), app: app)
        try studio.edit(ripple: false) { s throws(SessionError) in
            try s.trim("c1", to: 102_400..<153_600)
            try edit(&s)
        }
        let (window, view) = standaloneLanes(model, studio)
        return (model, studio, window, view)
    }

    func send(_ type: NSEvent.EventType, _ view: TimelineScrollView, _ x: Double, _ y: Double, clicks: Int = 1)
        throws
    {
        let event = try mouse(type, NSPoint(x: x, y: y), in: view, clicks: clicks)
        switch type {
        case .leftMouseDown: view.lanes.mouseDown(with: event)
        case .leftMouseDragged: view.lanes.mouseDragged(with: event)
        case .leftMouseUp: view.lanes.mouseUp(with: event)
        default: view.lanes.mouseMoved(with: event)
        }
    }

    /// The text of `readout` in the language of the app (the tables: `GainLineRendererTests`).
    func text(_ readout: GestureReadout) -> String {
        ReadoutLayer.text(readout, rate: 48_000, locale: .current) { $0.text }
    }

    func readout(_ view: TimelineScrollView) -> String? {
        view.lanes.readout.isHidden ? nil : view.lanes.readout.string as? String
    }

    @Test func aGainDragIsOneUndoEntry() async throws {
        let (model, studio, window, view) = try await lanes()
        let before = studio.session

        try send(.leftMouseDown, view, 250, 3)
        try send(.leftMouseDragged, view, 250, 13)
        #expect(view.lanes.inputs?.session.clip("c1")?.clip.gain == Gain(dB: -6), "the preview")
        #expect(studio.session == before)
        try send(.leftMouseUp, view, 250, 13)

        #expect(studio.session.clip("c1")?.clip.gain == Gain(dB: -6))
        #expect(model.timeline.selection == .clips(ClipSet("c1")))
        model.undo()
        #expect(studio.session == before, "one undo entry")
        window.close()
        await model.close()
    }

    @Test func aFadeHandleDragIsOneUndoEntry() async throws {
        let (model, studio, window, view) = try await lanes()
        let before = studio.session

        try send(.leftMouseDown, view, 204, 4)
        try send(.leftMouseDragged, view, 250, 4)
        try send(.leftMouseUp, view, 250, 4)

        #expect(studio.session.clip("c1")?.clip.fades == Fades(fadeIn: 23_552, fadeOut: 0))
        model.undo()
        #expect(studio.session == before, "one undo entry")
        window.close()
        await model.close()
    }

    @Test func escapeCancelsAGainDrag() async throws {
        let (model, studio, window, view) = try await lanes()
        let before = studio.session

        try send(.leftMouseDown, view, 250, 3)
        try send(.leftMouseDragged, view, 250, 13)
        #expect(view.lanes.inputs?.session != before, "the drag shows a preview")
        #expect(view.cancelGesture())
        #expect(view.lanes.inputs?.session == before)
        try send(.leftMouseUp, view, 250, 13)
        #expect(studio.session == before)
        window.close()
        await model.close()
    }

    /// 22,080 frames at 48 kHz are 460 ms. The readout hides after the up, Esc, and an undo.
    @Test func theReadoutShowsDuringADrag() async throws {
        let (model, studio, window, view) = try await lanes()
        #expect(readout(view) == nil)

        try send(.leftMouseDown, view, 250, 3)
        try send(.leftMouseDragged, view, 250, 13)
        #expect(readout(view) == text(.gain(Gain(dB: -6)!, from: .zero)))
        let frame = view.lanes.readout.frame
        let lanesInView = view.shown.intersection(view.lanes.bounds)
        #expect(frame.minX > 250 && lanesInView.contains(frame), "near the pointer, in the lanes in view")
        try send(.leftMouseUp, view, 250, 13)
        #expect(readout(view) == nil, "after the up")

        try send(.leftMouseDown, view, 204, 4)
        try send(.leftMouseDragged, view, 247.125, 4)
        #expect(readout(view) == text(.fade(.start, 22_080)))
        #expect(view.cancelGesture())
        #expect(readout(view) == nil, "after Esc")
        try send(.leftMouseUp, view, 247.125, 4)

        try send(.leftMouseDown, view, 250, 3)
        try send(.leftMouseDragged, view, 250, 13)
        model.undo()
        view.update(laneInputs(model, studio))
        #expect(readout(view) == nil, "after an undo during the drag")
        try send(.leftMouseUp, view, 250, 13)
        window.close()
        await model.close()
    }

    /// Code gate K2: during the autoscroll of a fade-handle drag the readout stays at the pointer,
    /// past the right edge of the lanes in view, while the lanes scroll under it.
    @Test func theReadoutFollowsThePointerDuringAutoscroll() async throws {
        let (model, _, window, view) = try await lanes()
        view.viewWillMove(toWindow: nil)
        try send(.leftMouseDown, view, 204, 4)
        let edge = Double(view.shown.maxX)
        try send(.leftMouseDragged, view, edge + 40, 4)

        for n in 0..<30 { view.autoscrollTick(at: 100 + Double(n) / 60) }

        #expect(view.origin / 512 > 100, "the lanes scrolled")
        #expect(readout(view) == text(.fade(.start, view.lanes.inputs?.session.clip("c1")?.clip.fades.fadeIn ?? 0)))
        #expect(abs(view.lanes.readout.frame.maxX - view.shown.maxX) <= 1, "\(view.lanes.readout.frame)")
        try send(.leftMouseUp, view, edge + 40, 4)
        window.close()
        await model.close()
    }

    /// A gain drag event redraws the columns of c1 only (x 200 to 300 with 1 pt on each side), and
    /// a mouse move over the handles and the line renders nothing.
    @Test func aGainDragRedrawsOnlyItsClip() async throws {
        let (model, _, window, view) = try await lanes()
        try send(.leftMouseDown, view, 250, 3)

        try send(.leftMouseDragged, view, 250, 13)
        drawNow(window)

        let rect = view.lanes.drawnRect
        #expect(rect.minX >= 199 && rect.maxX <= 301 && rect.width > 0, "\(rect)")
        try send(.leftMouseUp, view, 250, 13)
        window.close()
        await model.close()
    }

    /// R4 (run 11c-2): c9 joins c1 at x 300 with a crossfade of 20,480 frames (20 pt on each
    /// side). A gain drag of c1 redraws to x 320, where its fade line over c9 ends (fail value: x 301).
    @Test func aGainDragRedrawsTheCrossfadeLine() async throws {
        let (model, _, window, view) = try await lanes { s throws(SessionError) in
            try s.place(Clip(id: "c9", file: "f1", start: 153_600, offset: 300_000, length: 51_200), on: "t1")
            try s.setCrossfades(["c1": 20_480])
        }
        try send(.leftMouseDown, view, 250, 3)

        try send(.leftMouseDragged, view, 250, 13)
        drawNow(window)

        let rect = view.lanes.drawnRect
        #expect(rect.maxX >= 320 && rect.maxX <= 322, "\(rect)")
        try send(.leftMouseUp, view, 250, 13)
        window.close()
        await model.close()
    }

    @Test func aMouseMoveRendersNothing() async throws {
        let (model, _, window, view) = try await lanes()
        drawNow(window)
        let draws = view.lanes.draws

        for n in 0..<20 {
            try send(.mouseMoved, view, 200 + Double(n * 5), Double(n % 10))
            drawNow(window)
        }

        #expect(view.lanes.draws == draws)
        window.close()
        await model.close()
    }

    /// c9 is x 400 to 500 on t1 with frames from 102,400 of f1. A trim of its start to x 300 joins
    /// it to c1, so the fade-out handle of c1 (x 292 to 300) goes away: the event redraws it.
    @Test func aTrimToAButtJoinRedrawsTheNeighborHandle() async throws {
        let (model, _, window, view) = try await lanes { s throws(SessionError) in
            try s.place(Clip(id: "c9", file: "f1", start: 204_800, offset: 102_400, length: 51_200), on: "t1")
        }
        try send(.leftMouseDown, view, 401, 30)

        try send(.leftMouseDragged, view, 301, 30)
        drawNow(window)

        #expect(view.lanes.inputs?.session.clip("c9")?.clip.start == 153_600, "the join")
        #expect(view.lanes.drawnRect.minX <= 292, "\(view.lanes.drawnRect)")
        try send(.leftMouseUp, view, 301, 30)
        window.close()
        await model.close()
    }

    /// c1 at -6 dB: its line is at y 10, and its band is y 7 to 13.
    @Test func aDoubleClickResetsTheGain() async throws {
        let (model, studio, window, view) = try await lanes { s throws(SessionError) in
            try s.setGain(Gain(dB: -6)!, clip: "c1")
        }
        let before = studio.session

        try send(.leftMouseDown, view, 250, 10, clicks: 2)
        try send(.leftMouseUp, view, 250, 10, clicks: 2)
        #expect(studio.session.clip("c1")?.clip.gain == .zero)
        try send(.leftMouseDown, view, 250, 3, clicks: 2)
        try send(.leftMouseUp, view, 250, 3, clicks: 2)

        model.undo()
        #expect(studio.session == before, "one undo entry, the second double-click made none")
        window.close()
        await model.close()
    }

    /// C24 and C24b: over 0 dB the gain line stays on the lane top, so the readout shows a bar:
    /// a drag from +6.0 dB to +4.0 dB moves the marker left by 2/40 of the bar, and the text shows
    /// the change since the mouse-down at +8.0 dB.
    @Test func theReadoutMarkerMovesAboveZero() async throws {
        let (model, _, window, view) = try await lanes { s throws(SessionError) in
            try s.setGain(Gain(dB: 8)!, clip: "c1")
        }
        let bar = view.lanes.readout.bar
        try send(.leftMouseDown, view, 250, 3)
        // A drag starts after a few points: the first event goes to +6.0 dB.
        try send(.leftMouseDragged, view, 250, 3 + 2 / 0.6)
        try #require(readout(view) == text(.gain(Gain(dB: 6)!, from: Gain(dB: 8)!)))
        let start = view.lanes.readout.marker.frame.midX
        #expect(!bar.isHidden && bar.frame.width >= 80, "the gain readout shows the bar: \(bar.frame)")

        try send(.leftMouseDragged, view, 250, 3 + 4 / 0.6)
        #expect(readout(view) == text(.gain(Gain(dB: 4)!, from: Gain(dB: 8)!)))
        let moved = start - view.lanes.readout.marker.frame.midX
        #expect(abs(moved - bar.frame.width * 2 / 40) <= 1, "the marker moved \(moved) pt on \(bar.frame.width) pt")
        let geometry = try #require(
            LaneGeometry(scale: TimelineScale(framesPerPoint: 512), laneHeight: 100, range: .standard))
        let clip = try #require(view.lanes.inputs?.session.clip("c1")?.clip)
        #expect(geometry.gainLineY(clip, trackGain: .zero, lane: 0) == 0, "the line stays on the lane top")
        try send(.leftMouseUp, view, 250, 3 + 4 / 0.6)
        window.close()
        await model.close()
    }

    /// C25: the bar ends are the gain limits, so a gain outside them puts the marker at the end.
    @Test func theReadoutMarkerStopsAtTheBarEnds() {
        #expect(ReadoutLayer.markerX(Gain(dB: 0)!, barWidth: 80) == 40)
        #expect(ReadoutLayer.markerX(Gain(dB: 20)!, barWidth: 80) == 80)
        #expect(ReadoutLayer.markerX(Gain(dB: 24)!, barWidth: 80) == 80)
        #expect(ReadoutLayer.markerX(Gain(dB: -30)!, barWidth: 80) == 0)
    }

    /// C26: a fade readout has no bar.
    @Test func aFadeReadoutHasNoBar() async throws {
        let (model, _, window, view) = try await lanes()
        try send(.leftMouseDown, view, 204, 4)
        try send(.leftMouseDragged, view, 247.125, 4)
        try #require(readout(view) == text(.fade(.start, 22_080)))
        #expect(view.lanes.readout.bar.isHidden && view.lanes.readout.marker.isHidden)
        try send(.leftMouseUp, view, 247.125, 4)
        window.close()
        await model.close()
    }
}
