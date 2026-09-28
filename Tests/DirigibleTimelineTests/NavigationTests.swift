import DirigibleCore
import Testing

@testable import DirigibleTimeline

/// Timeline-navigation criteria N9 to N12 (the pure part): the page, the center, the clamps, the
/// document width, and the hold of the scale during a lane gesture. The view is 1440 pt wide at
/// 512 frames per point (737,280 visible frames) on a 2 h session at 48 kHz unless a test says
/// otherwise.
struct NavigationTests {
    static let twoHours = Frames(48_000 * 7200)
    static let scale = TimelineScale(framesPerPoint: 512)

    static func viewport(origin: Double, scale: TimelineScale = scale) -> Viewport {
        Viewport(scale: scale, origin: origin, width: 1440, end: twoHours, rate: 48_000)
    }

    static func handle(_ input: NavigationInput, origin: Double = 0, holdsScale: Bool = false) -> Zoom? {
        var navigation = Navigation()
        return navigation.handle(
            input, NavigationContext(viewport: viewport(origin: origin), playhead: 0, holdsScale: holdsScale))
    }

    /// 0.9 x 737,280 = 663,552 frames. The last origin is (688,500 - 1440) pt x 512 = 351,774,720.
    @Test func pageMovesNinetyPercentAndStopsAtTheEnds() {
        #expect(Self.handle(.page(.forward), origin: 0)?.origin == 663_552, "page right moves 663552 frames")
        #expect(Self.handle(.page(.forward), origin: 0)?.scale == Self.scale, "a page keeps the scale")
        #expect(Self.handle(.page(.backward), origin: 1_000_000)?.origin == 336_448, "page left moves 663552 frames")
        #expect(
            Self.handle(.page(.forward), origin: 351_500_000)?.origin == 351_774_720, "the last page stops at the end")
        #expect(Self.handle(.page(.backward), origin: 100_000)?.origin == 0, "the first page stops at 0")
    }

    @Test func centerPutsTheFrameInTheMiddle() {
        #expect(Self.handle(.center(1_000_000))?.origin == 631_360, "the frame is at the middle")
        #expect(Self.handle(.center(100_000))?.origin == 0, "the center stops at 0")
        #expect(Self.handle(.center(352_500_000))?.origin == 351_774_720, "the center stops at the end")
        #expect(Self.handle(.scroll(to: 2_000_000))?.origin == 2_000_000, "a scroll goes to its origin")
        #expect(Self.handle(.scroll(to: -5))?.origin == 0, "a scroll stops at 0")
    }

    /// The closest zoom is 128 frames per point; the fit of 2 h + 2% over 1440 pt is 244,800.
    @Test func zoomToClampsTheScaleAndTheOrigin() {
        let closer = Self.handle(.zoomTo(Zoom(scale: TimelineScale(framesPerPoint: 64), origin: -5), stroke: .changed))
        #expect(closer == Zoom(scale: TimelineScale(framesPerPoint: 128), origin: 0), "the closest zoom is 128")
        let farther = Self.handle(
            .zoomTo(Zoom(scale: TimelineScale(framesPerPoint: 1e9), origin: 5_000_000), stroke: .changed))
        #expect(farther == Zoom(scale: TimelineScale(framesPerPoint: 244_800), origin: 0), "the fit is the farthest")
        let inside = Self.handle(
            .zoomTo(Zoom(scale: TimelineScale(framesPerPoint: 1000), origin: 3_000_000), stroke: .changed))
        #expect(inside == Zoom(scale: TimelineScale(framesPerPoint: 1000), origin: 3_000_000), "a zoom in range stays")
        #expect(
            Self.handle(.fitSession, origin: 2_000_000)
                == Zoom(scale: TimelineScale(framesPerPoint: 244_800), origin: 0), "Zoom to Session")
    }

    /// The formula of `TimelineDocumentView.resize()`: max(end, 10 s) + 2% at the zoom, whole
    /// points, and at least the width in view.
    @Test func documentWidthIsTheWidthOfTheLanes() {
        func width(_ end: Frames, _ framesPerPoint: Double) -> Double {
            Viewport.documentWidth(
                end: end, rate: 48_000, scale: TimelineScale(framesPerPoint: framesPerPoint), shown: 1440)
        }
        #expect(width(Self.twoHours, 244_800) == 1440, "the document is 1440 pt at the fit")
        #expect(width(Self.twoHours, 512) == 688_500, "the document is 688500 pt at 512 frames per point")
        #expect(width(48_000, 128) == 3825, "a short session is 10 s wide")
        #expect(width(48_000, 400) == 1440, "the document is at least the width in view")
    }

    @Test func aLaneGestureHoldsTheScale() {
        #expect(Self.handle(.zoom(by: 0.5), holdsScale: true) == nil, "a lane gesture holds the scale")
        #expect(Self.handle(.fitSession, holdsScale: true) == nil, "a lane gesture holds the scale")
        #expect(
            Self.handle(.zoomTo(Zoom(scale: Self.scale, origin: 0), stroke: .changed), holdsScale: true) == nil,
            "a lane gesture holds the scale")
        #expect(Self.handle(.scroll(to: 1000), holdsScale: true)?.origin == 1000, "a scroll still applies")
        #expect(Self.handle(.zoom(by: 0.5))?.scale.framesPerPoint == 256, "with no gesture the zoom applies")
    }

    /// The keys zoom at the playhead when it is in view (0017).
    @Test func zoomByKeepsTheAnchor() {
        let zoomed = Self.handle(.zoom(by: 0.5, at: 400), origin: 1_000_000)
        #expect(zoomed == Zoom(scale: TimelineScale(framesPerPoint: 256), origin: 1_102_400), "the pointer stays")
    }
}

/// Criterion N3 and N8 (the pure part): the double-click toggle of the strip, and the position of
/// the view for the accessibility value.
struct NavigationToggleTests {
    static let zoomed = Zoom(scale: TimelineScale(framesPerPoint: 512), origin: 900_000)
    static let fit = Zoom(scale: TimelineScale(framesPerPoint: 244_800), origin: 0)

    static func context(_ zoom: Zoom) -> NavigationContext {
        NavigationContext(
            viewport: NavigationTests.viewport(origin: zoom.origin, scale: zoom.scale), playhead: 0, holdsScale: false)
    }

    /// U10, plan gate item 1: the first click centered the view at 1,000,000 before the second click.
    @Test func aDoubleClickTogglesTheFit() {
        var navigation = Navigation()
        let centered = Zoom(scale: Self.zoomed.scale, origin: 1_000_000)
        #expect(navigation.handle(.toggleFit(before: Self.zoomed), Self.context(centered)) == Self.fit)
        #expect(
            navigation.handle(.toggleFit(before: Self.fit), Self.context(Self.fit)) == Self.zoomed,
            "a second double-click goes back")
        #expect(
            navigation.handle(.toggleFit(before: Self.zoomed), Self.context(Self.zoomed)) == Self.fit,
            "a third double-click fits again")
    }

    @Test func aDoubleClickAtTheFitWithNoMemoryDoesNothing() {
        var navigation = Navigation()
        #expect(navigation.handle(.toggleFit(before: Self.fit), Self.context(Self.fit)) == nil)
    }

    /// After a zoom away from the fit, the memory does not apply: the double-click fits.
    @Test func aDoubleClickAfterAnotherZoomFits() {
        var navigation = Navigation()
        _ = navigation.handle(.toggleFit(before: Self.zoomed), Self.context(Self.zoomed))
        let other = Zoom(scale: TimelineScale(framesPerPoint: 1024), origin: 0)
        #expect(navigation.handle(.toggleFit(before: other), Self.context(other)) == Self.fit)
    }

    /// U15, plan gate item 3: origin / (extent - frames in view), 0 when that is 0 or less, and
    /// clamped to 0...1. At 700 frames per point the last page is 300 frames past extent - frames.
    @Test func thePositionIsFromZeroToOne() {
        #expect(NavigationTests.viewport(origin: 175_887_360).position == 0.5, "the value is 0.5 at the middle")
        #expect(
            NavigationTests.viewport(origin: 0, scale: Self.fit.scale).position == 0, "the value is 0 at the fit")
        var navigation = Navigation()
        let wide = NavigationTests.viewport(origin: 0, scale: TimelineScale(framesPerPoint: 700))
        let last = navigation.handle(
            .scroll(to: 400_000_000), NavigationContext(viewport: wide, playhead: 0, holdsScale: false))
        #expect(last?.origin == 351_504_300)
        let shown = NavigationTests.viewport(origin: last?.origin ?? 0, scale: TimelineScale(framesPerPoint: 700))
        #expect(shown.position == 1, "the value is 1 at the last page")
    }
}

/// Criterion N9 and N10 (the pure part): the zoom history, the strokes, H and back, and smart
/// zoom. A view is 1440 pt of a 2 h session at 48 kHz; the fit is 244,800 frames per point.
struct ZoomHistoryTests {
    static let fit = NavigationToggleTests.fit
    static func at(_ framesPerPoint: Double, _ origin: Double = 0) -> Zoom {
        Zoom(scale: TimelineScale(framesPerPoint: framesPerPoint), origin: origin)
    }

    var navigation = Navigation()
    var view = at(512, 1_000_000)

    /// Sends `input` from the current view and shows the result.
    mutating func send(_ input: NavigationInput) {
        if let zoom = navigation.handle(input, NavigationToggleTests.context(view)) { view = zoom }
    }

    @Test mutating func backAndForwardWalkTheZooms() {
        send(.zoom(by: 0.5, at: 0))
        #expect(view == Self.at(256, 1_000_000))
        send(.fitSession)
        #expect(navigation.canGoBack && !navigation.canGoForward)
        send(.back)
        #expect(view == Self.at(256, 1_000_000))
        send(.back)
        #expect(view == Self.at(512, 1_000_000))
        #expect(!navigation.canGoBack && navigation.canGoForward)
        send(.forward)
        send(.forward)
        #expect(view == Self.fit)
        send(.back)
        send(.zoom(by: 0.5, at: 0))
        #expect(!navigation.canGoForward, "a new zoom clears Forward")
    }

    @Test mutating func aScrollMakesNoEntry() {
        send(.scroll(to: 2_000_000))
        send(.page(.forward))
        send(.center(5_000_000))
        #expect(!navigation.canGoBack, "a scroll makes no entry")
    }

    @Test mutating func theHistoryKeepsFiftyEntries() {
        for n in 0..<60 { send(.zoomTo(Self.at(1000 + Double(n)), stroke: .began)) }
        // A limit: a Back that never ends must fail the test, not hang it.
        var steps = 0
        while navigation.canGoBack, steps < 100 {
            send(.back)
            steps += 1
        }
        #expect(steps == 50, "the history keeps 50 entries")
        #expect(view == Self.at(1009), "the oldest entries go first")
    }

    @Test mutating func aPinchIsOneEntry() {
        send(.zoom(by: 0.9, at: 100, stroke: .began))
        for _ in 0..<10 { send(.zoom(by: 0.9, at: 100, stroke: .changed)) }
        send(.zoom(by: 0.9, at: 100, stroke: .ended))
        send(.zoom(by: 0.9, at: 100, stroke: .momentum(ended: false)))
        send(.zoom(by: 0.9, at: 100, stroke: .momentum(ended: true)))
        send(.back)
        #expect(view == Self.at(512, 1_000_000), "a pinch makes one entry")
        #expect(!navigation.canGoBack, "momentum after the end makes no entry")
    }

    @Test mutating func aLostBeganStillMakesAnEntry() {
        send(.zoom(by: 0.5, at: 0))
        send(.zoom(by: 0.9, at: 100, stroke: .changed))
        send(.back)
        send(.back)
        #expect(view == Self.at(512, 1_000_000))
    }

    /// Code gate 1 item 5: a pinch with a lost began after an ended pinch is not its momentum,
    /// so it makes its own entry.
    @Test mutating func aLostBeganAfterAnEndedStrokeMakesAnEntry() {
        send(.zoom(by: 2, at: 0, stroke: .began))
        send(.zoom(by: 2, at: 0, stroke: .ended))
        let first = view
        send(.zoom(by: 2, at: 0, stroke: .changed))
        #expect(view == Self.at(4096, 1_000_000))
        send(.back)
        #expect(view == first, "a lost began after an ended stroke makes an entry")
    }

    /// Code gate 2 item 3: a stroke whose first event does not change the view is still one entry:
    /// the event that changes the view makes it.
    @Test mutating func aStrokeThatStartsWithNoChangeMakesAnEntry() {
        let before = view
        send(.zoom(by: 1.0, at: 100, stroke: .began))
        send(.zoom(by: 0.9, at: 100, stroke: .changed))
        #expect(view != before)
        send(.back)
        #expect(view == before, "a began with no change opens no stroke")
    }

    /// Code gate 2 item 3: 128 frames per point is the closest zoom, so a began that zooms in
    /// changes nothing; the zoom out after it makes the entry.
    @Test mutating func aBeganClampedAtTheClosestZoomMakesAnEntry() {
        view = Self.at(128, 1_000_000)
        send(.zoom(by: 0.5, at: 0, stroke: .began))
        #expect(view == Self.at(128, 1_000_000), "the closest zoom is 128")
        send(.zoom(by: 2, at: 0, stroke: .changed))
        #expect(view == Self.at(256, 1_000_000))
        send(.back)
        #expect(view == Self.at(128, 1_000_000), "a clamped began opens no stroke")
    }

    /// A began with no change ends the stroke before it, also when that stroke lost its end.
    @Test mutating func aBeganWithNoChangeEndsTheOpenStroke() {
        send(.zoom(by: 2, at: 0, stroke: .began))
        let first = view
        send(.zoom(by: 1.0, at: 0, stroke: .began))
        send(.zoom(by: 2, at: 0, stroke: .changed))
        send(.back)
        #expect(view == first, "a began with no change ends the open stroke")
    }

    /// A changed with no change continues the stroke: the pinch is still one entry.
    @Test mutating func aChangedWithNoChangeContinuesTheStroke() {
        let before = view
        send(.zoom(by: 0.9, at: 100, stroke: .began))
        send(.zoom(by: 1.0, at: 100, stroke: .changed))
        send(.zoom(by: 0.9, at: 100, stroke: .changed))
        send(.back)
        #expect(view == before, "a changed with no change continues the stroke")
    }

    /// A pinch ends with a magnification of 0: an end with no change still ends the stroke, so a
    /// lost began after it makes its own entry.
    @Test mutating func anEndWithNoChangeEndsTheStroke() {
        send(.zoom(by: 2, at: 0, stroke: .began))
        send(.zoom(by: 1.0, at: 0, stroke: .ended))
        let first = view
        send(.zoom(by: 2, at: 0, stroke: .changed))
        send(.back)
        #expect(view == first, "an end with no change ends the stroke")
    }

    /// Code gate 1 item 4: Esc of an overview edge drag puts back Back and Forward as they were
    /// before its began.
    @Test mutating func aCancelledStrokeKeepsTheHistory() {
        send(.zoom(by: 0.5, at: 0))
        send(.back)
        let before = view
        send(.zoomTo(Self.at(300, 1_000_000), stroke: .began))
        send(.zoomTo(Self.at(200, 1_000_000), stroke: .changed))
        send(.zoomTo(before, stroke: .cancelled))
        #expect(view == before)
        #expect(!navigation.canGoBack, "Esc leaves no Back step")
        send(.forward)
        #expect(view == Self.at(256, 1_000_000), "Esc keeps Zoom Forward")
    }

    /// Code gate 3 item 4: a began with no change opens no stroke, so the changed after it keeps
    /// the history for Esc.
    @Test mutating func aCancelAfterABeganWithNoChangeKeepsTheHistory() {
        send(.zoom(by: 0.5, at: 0))
        send(.back)
        let before = view
        send(.zoomTo(before, stroke: .began))
        send(.zoomTo(Self.at(200, 1_000_000), stroke: .changed))
        #expect(view == Self.at(200, 1_000_000), "the changed zooms")
        send(.zoomTo(before, stroke: .cancelled))
        #expect(view == before)
        #expect(!navigation.canGoBack, "Esc after a began with no change leaves no Back step")
        send(.forward)
        #expect(view == Self.at(256, 1_000_000), "Esc after a began with no change keeps Zoom Forward")
    }

    /// A wheel burst: under 0.5 s between events is one entry (a calibration value).
    @Test mutating func aWheelGapSplitsTheEntries() {
        send(.zoom(by: 0.9, at: 100, stroke: .wheel(time: 10), wheel: 10))
        send(.zoom(by: 0.9, at: 100, stroke: .wheel(time: 10.4), wheel: 10.4))
        send(.back)
        #expect(view == Self.at(512, 1_000_000) && !navigation.canGoBack, "a 0.4 s gap is one entry")
        var other = Navigation()
        var zoom = Self.at(512, 1_000_000)
        for time in [20.0, 20.6] {
            zoom =
                other.handle(
                    .zoom(by: 0.9, at: 100, stroke: .wheel(time: time), wheel: time),
                    NavigationToggleTests.context(zoom))
                ?? zoom
        }
        _ = other.handle(.back, NavigationToggleTests.context(zoom))
        #expect(other.canGoBack, "a 0.6 s gap is two entries")
    }

    /// Plan gate item 6: momentum events carry the wheel time, so a burst goes on through them.
    @Test mutating func momentumKeepsTheWheelBurstOpen() {
        send(.zoom(by: 0.9, at: 100, stroke: .wheel(time: 10), wheel: 10))
        send(.zoom(by: 0.9, at: 100, stroke: .momentum(ended: false), wheel: 10.4))
        send(.zoom(by: 0.9, at: 100, stroke: .wheel(time: 10.8), wheel: 10.8))
        send(.back)
        #expect(!navigation.canGoBack, "momentum keeps the wheel burst open")
    }

    /// Q4 (U3): H with no selection fits the session; a second H with the view unchanged goes
    /// back; after a scroll H zooms to the selection again.
    @Test mutating func hTogglesAndGoesBack() {
        send(.toggleSelection(480_000..<960_000))
        #expect(abs(view.scale.framesPerPoint - 366.667) < 0.001 && view.origin == 456_000)
        send(.toggleSelection(480_000..<960_000))
        #expect(view == Self.at(512, 1_000_000), "an unchanged view goes back")
        // The clip view puts the origin on a pixel: half a point off is still the same view.
        send(.toggleSelection(480_000..<960_000))
        view.origin += view.scale.framesPerPoint / 2
        send(.toggleSelection(480_000..<960_000))
        #expect(view == Self.at(512, 1_000_000), "an unchanged view goes back")
        send(.toggleSelection(480_000..<960_000))
        send(.scroll(to: 470_000))
        send(.toggleSelection(480_000..<960_000))
        #expect(view.origin == 456_000, "a scrolled view zooms to the selection again")
        send(.toggleSelection(nil))
        #expect(view == Self.fit, "H with no selection fits the session")
        send(.toggleSelection(nil))
        #expect(view.origin == 456_000, "H with no selection goes back")
    }

    /// The last page of a selection at the session end is clamped; the second H still goes back.
    @Test mutating func hTwiceNearTheSessionEndGoesBack() {
        send(.toggleSelection(346_000_000..<352_400_000))
        #expect(view != Self.at(512, 1_000_000))
        send(.toggleSelection(346_000_000..<352_400_000))
        #expect(view == Self.at(512, 1_000_000), "an unchanged view goes back")
    }

    /// Plan gate item 1: the double-click pushes the view before its first click.
    @Test mutating func aDoubleClickPushesTheViewOfTheFirstClick() {
        let before = view
        view = Self.at(512, 1_200_000)
        send(.toggleFit(before: before))
        send(.back)
        #expect(view == before, "the double-click goes back to the view before the first click")
    }

    /// U11: at the fit, smart zoom shows the clip under the pointer, or 8x at the pointer with no
    /// clip; elsewhere it fits the session.
    @Test mutating func smartZoomFollowsTheSystemRule() {
        view = Self.fit
        send(.smartZoom(at: 720, clip: 48_000_000..<96_000_000))
        #expect(view.origin == 45_600_000, "smart zoom shows the clip under the pointer")
        send(.smartZoom(at: 720, clip: nil))
        #expect(view == Self.fit, "smart zoom away from the fit fits the session")
        send(.smartZoom(at: 720, clip: nil))
        #expect(view.scale.framesPerPoint == 30_600, "smart zoom at the fit zooms in")
        #expect(view.origin == 176_256_000 - 720 * 30_600, "the pointer frame stays")
        send(.back)
        #expect(view == Self.fit)
    }
}

/// Plan gate item 6: the stroke of a wheel or pinch event from its phase and momentum phase.
struct StrokeTests {
    @Test func theMapFromAnEvent() {
        #expect(Stroke(phase: .began, momentum: .none, time: 3) == .began)
        #expect(Stroke(phase: .changed, momentum: .none, time: 3) == .changed)
        #expect(Stroke(phase: .ended, momentum: .none, time: 3) == .ended)
        #expect(Stroke(phase: .cancelled, momentum: .none, time: 3) == .ended)
        // Code gate 1 item 5: momentum is its own case, so a lost began is not momentum.
        #expect(Stroke(phase: .none, momentum: .changed, time: 3) == .momentum(ended: false))
        #expect(Stroke(phase: .none, momentum: .began, time: 3) == .momentum(ended: false))
        #expect(Stroke(phase: .none, momentum: .ended, time: 3) == .momentum(ended: true))
        #expect(Stroke(phase: .none, momentum: .cancelled, time: 3) == .momentum(ended: true))
        #expect(Stroke(phase: .none, momentum: .none, time: 3) == .wheel(time: 3))
    }
}
