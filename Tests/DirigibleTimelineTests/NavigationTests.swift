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
