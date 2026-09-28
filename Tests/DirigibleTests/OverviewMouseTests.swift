import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleTimeline
import Testing

@testable import DirigibleApp

/// Timeline-navigation criteria N7 and N8: the mouse on the overview strip, Esc, the tooltip, and
/// the strip as one accessibility element. The pane of `stripPane`: a 20 s session (979,200 frames
/// of extent) on a 1780 pt strip, 550.11 frames per strip point; the lanes are 1440 pt wide.
@Suite(.serialized) @MainActor struct OverviewMouseTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)
    static let stripFramesPerPoint = 979_200.0 / 1780

    init() throws { folder = try TemporaryFolder() }

    /// A mouse event on the strip at the strip x `x`, sent to the strip (the hit view).
    func send(_ type: NSEvent.EventType, _ x: Double, clicks: Int = 1, to strip: OverviewStrip) throws {
        let event = try #require(
            NSEvent.mouseEvent(
                with: type, location: strip.convert(NSPoint(x: x, y: 14), to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: strip.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: clicks,
                pressure: 1))
        switch type {
        case .leftMouseDown: strip.mouseDown(with: event)
        case .leftMouseDragged: strip.mouseDragged(with: event)
        default: strip.mouseUp(with: event)
        }
    }

    func zoom(_ view: TimelineScrollView, _ framesPerPoint: Double, origin: Double) {
        view.navigate(
            .zoomTo(Zoom(scale: TimelineScale(framesPerPoint: framesPerPoint), origin: origin), stroke: .changed))
    }

    @Test func aClickCentersTheLanesOnThatTime() async throws {
        let (model, _, window, pane) = try await stripPane(folder, app)
        let (view, strip) = (pane.scroll, pane.overview)
        zoom(view, 128, origin: 0)
        try send(.leftMouseDown, 1000, to: strip)
        try send(.leftMouseUp, 1000, to: strip)
        let center = Double(Int(1000 * Self.stripFramesPerPoint))
        #expect(abs(view.origin - (center - 92_160)) <= 128, "a click centers the lanes: \(view.origin)")
        #expect(strip.toolTip == L10n.timelineOverviewHelp.text, "the tooltip")
        window.close()
        await model.close()
    }

    @Test func aFrameDragScrollsAndEscRestores() async throws {
        let (model, _, window, pane) = try await stripPane(folder, app)
        let (view, strip) = (pane.scroll, pane.overview)
        zoom(view, 128, origin: 0)
        try send(.leftMouseDown, 100, to: strip)
        try send(.leftMouseDragged, 110, to: strip)
        #expect(abs(view.origin - 10 * Self.stripFramesPerPoint) <= 128, "a 10 pt drag moves 10 x the strip scale")
        #expect(view.cancelOverview(), "Esc ends the drag")
        #expect(view.origin == 0, "Esc gives the origin of the mouse-down")
        #expect(!view.cancelOverview(), "no drag after Esc")
        window.close()
        await model.close()
    }

    /// The trailing edge of a 335 pt frame moves to x 400; the leading edge stays at 0.
    @Test func anEdgeDragZoomsAndKeepsTheOtherEdge() async throws {
        let (model, _, window, pane) = try await stripPane(folder, app)
        let (view, strip) = (pane.scroll, pane.overview)
        zoom(view, 128, origin: 0)
        try send(.leftMouseDown, 335, to: strip)
        try send(.leftMouseDragged, 400, to: strip)
        try send(.leftMouseUp, 400, to: strip)
        #expect(view.origin == 0, "the leading edge stays")
        #expect(abs(view.framesPerPoint - 400 * Self.stripFramesPerPoint / 1440) < 0.01, "\(view.framesPerPoint)")
        window.close()
        await model.close()
    }

    /// Plan gate item 1: the real sequence (down 1, up, down 2, up) from a zoomed and scrolled
    /// view. The first click centers the view; the double-click fits, and the next one goes back to
    /// the view before the first click.
    @Test func aDoubleClickFromAZoomedViewGoesBackToIt() async throws {
        let (model, _, window, pane) = try await stripPane(folder, app)
        let (view, strip) = (pane.scroll, pane.overview)
        zoom(view, 128, origin: 300_000)
        for clicks in [1, 2] {
            try send(.leftMouseDown, 1200, clicks: clicks, to: strip)
            try send(.leftMouseUp, 1200, clicks: clicks, to: strip)
        }
        #expect(abs(view.framesPerPoint - 680) < 0.01 && view.origin == 0, "a double-click fits the session")
        for clicks in [1, 2] {
            try send(.leftMouseDown, 800, clicks: clicks, to: strip)
            try send(.leftMouseUp, 800, clicks: clicks, to: strip)
        }
        #expect(
            view.framesPerPoint == 128 && abs(view.origin - 300_000) <= 128,
            "a second double-click goes back: \(view.framesPerPoint), \(view.origin)")
        window.close()
        await model.close()
    }

    /// Esc order: a header drag, an overview drag, a lane gesture, then the Marks.
    @Test func escEndsTheOverviewDragBeforeTheLaneGesture() async throws {
        let (model, _, window, view) = try await openLanes(
            app, try await timelinePackage(in: folder.url, tracks: 2, seconds: 20))
        let strip = try #require(view.overview)
        view.viewWillMove(toWindow: nil)
        view.lanes.mouseDown(with: try mouse(.leftMouseDown, NSPoint(x: 100, y: 20), in: view))
        try #require(view.gesture.isActive, "a lane gesture")
        try send(.leftMouseDown, 100, to: strip)
        try send(.leftMouseDragged, 120, to: strip)
        try #require(view.overviewGesture.isActive, "an overview drag")
        window.cancelOperation(nil)
        #expect(!view.overviewGesture.isActive && view.gesture.isActive, "Esc ends the overview drag first")
        window.cancelOperation(nil)
        #expect(!view.gesture.isActive, "the next Esc ends the lane gesture")
        await model.close()
    }

    /// N8 (U15, plan gate item 3): one element with the role scroll bar, a value from 0 to 1, a
    /// value description, page increments, the Show Whole Session action, and a value change only
    /// after a discrete input.
    @Test func theOverviewIsOneAccessibilityElement() async throws {
        let (model, _, window, pane) = try await stripPane(folder, app)
        let (view, strip) = (pane.scroll, pane.overview)
        #expect(strip.isAccessibilityElement())
        #expect(strip.accessibilityRole() == .scrollBar, "the overview is a scroll bar")
        #expect(strip.accessibilityLabel() == L10n.timelineOverview.text)
        func found(_ element: Any) -> Bool {
            if (element as AnyObject) === strip { return true }
            let children =
                (element as? NSView)?.accessibilityChildren()
                ?? (element as? NSAccessibilityElement)?
                .accessibilityChildren()
            return (children ?? []).contains { found($0) }
        }
        #expect(found(try #require(window.contentView)), "the window tree reaches the strip")

        view.navigate(.fitSession)
        #expect(strip.accessibilityValue() as? Double == 0, "the value is 0 at the fit")
        func time(_ seconds: Double) -> String { rulerLabel(seconds, tenths: false) }
        #expect(
            strip.accessibilityValueDescription() == L10n.timelineOverviewValue.format(time(0), time(20.4), time(20)))

        zoom(view, 128, origin: 0)
        #expect(strip.accessibilityPerformIncrement())
        #expect(view.origin == 165_888, "increment shows the next page")
        #expect(strip.accessibilityPerformDecrement())
        #expect(view.origin == 0, "decrement shows the page before")
        let action = try #require(strip.accessibilityCustomActions()?.first)
        #expect(action.name == L10n.timelineOverviewFit.text)
        #expect(action.handler?() == true)
        #expect(abs(view.framesPerPoint - 680) < 0.01, "Show Whole Session fits the session")

        zoom(view, 128, origin: 0)
        var posted = strip.valueChanges
        try send(.leftMouseDown, 1000, to: strip)
        try send(.leftMouseUp, 1000, to: strip)
        #expect(strip.valueChanges == posted + 1, "one value change after a click")
        posted = strip.valueChanges
        try send(.leftMouseDown, 1000, to: strip)
        for n in 1...20 { try send(.leftMouseDragged, 1000 - Double(n) * 5, to: strip) }
        #expect(strip.valueChanges == posted, "no value change during a drag")
        try send(.leftMouseUp, 900, to: strip)
        #expect(strip.valueChanges == posted + 1, "one value change at the end of a drag")
        posted = strip.valueChanges
        let play = Playback.playing(Shuttle(direction: .forward, rate: .one))
        for n in 0..<60 { view.tick(playhead: 400_000 + Double(n) * 20_000, playback: play) }
        #expect(strip.valueChanges == posted, "no value change during play")
        window.close()
        await model.close()
    }
}
