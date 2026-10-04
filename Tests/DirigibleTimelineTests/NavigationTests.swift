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
