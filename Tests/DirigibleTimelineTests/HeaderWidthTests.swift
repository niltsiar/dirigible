import Testing

@testable import DirigibleTimeline

/// Run 1b criteria H1 and H2: the header width clamps to 180...480 pt and rounds to whole points;
/// the drag state machine follows the states x events table of the ui-shell design.
struct HeaderWidthTests {
    @Test func theWidthClampsAndRounds() {
        #expect(HeaderWidth(100).points == 180, "clamp")
        #expect(HeaderWidth(180).points == 180, "clamp")
        #expect(HeaderWidth(480).points == 480, "clamp")
        #expect(HeaderWidth(500).points == 480, "clamp")
        #expect(HeaderWidth(.infinity).points == 480, "clamp")
        #expect(HeaderWidth(-.infinity).points == 180, "clamp")
        #expect(HeaderWidth(340.4).points == 340, "rounds to whole points")
        #expect(HeaderWidth(340.6).points == 341, "rounds to whole points")
        #expect(HeaderWidth(.nan).points == 340, "NaN gives the standard width")
        #expect(HeaderWidth.standard.points == 340, "NaN gives the standard width")
    }

    /// 0024 P11: the key and its value type never change.
    @Test func theKeyIsFrozen() {
        #expect(HeaderWidth.defaultsKey == "timeline.header.width", "frozen key")
    }
}

struct PaneDragTests {
    var drag = PaneDrag<HeaderWidth>()
    let w340 = HeaderWidth(340)

    @Test mutating func aDragIsLiveAndSavesAtTheUp() {
        #expect(drag.handle(.down(x: 338, clicks: 1), width: w340) == PaneDragStep(width: w340, save: false))
        #expect(drag.grab == -2, "grab")
        #expect(
            drag.handle(.drag(x: 400), width: w340) == PaneDragStep(width: HeaderWidth(402), save: false),
            "live width")
        #expect(
            drag.handle(.drag(x: 420), width: HeaderWidth(402)) == PaneDragStep(width: HeaderWidth(422), save: false),
            "no save")
        #expect(
            drag.handle(.up, width: HeaderWidth(422)) == PaneDragStep(width: HeaderWidth(422), save: true),
            "save at the up")
        #expect(!drag.isActive)
    }

    @Test mutating func anUpWithNoMoveSavesNothing() {
        _ = drag.handle(.down(x: 338, clicks: 1), width: w340)
        #expect(drag.handle(.up, width: w340) == PaneDragStep(width: w340, save: false), "no save")
    }

    /// A drag away and back to the start width saves nothing: the up compares with the start.
    @Test mutating func anUpAtTheStartWidthSavesNothing() {
        _ = drag.handle(.down(x: 338, clicks: 1), width: w340)
        _ = drag.handle(.drag(x: 400), width: w340)
        #expect(drag.handle(.drag(x: 338), width: HeaderWidth(402)) == PaneDragStep(width: w340, save: false))
        #expect(drag.handle(.up, width: w340) == PaneDragStep(width: w340, save: false), "no save")
    }

    /// The up compares the width with the start, not with the width of the last event.
    @Test mutating func anUpAfterAMoveSavesAlsoWithNoLastMove() {
        _ = drag.handle(.down(x: 338, clicks: 1), width: w340)
        _ = drag.handle(.drag(x: 400), width: w340)
        #expect(
            drag.handle(.up, width: HeaderWidth(402)) == PaneDragStep(width: HeaderWidth(402), save: true),
            "save at the up")
    }

    @Test mutating func escGivesTheStartWidth() {
        _ = drag.handle(.down(x: 338, clicks: 1), width: w340)
        _ = drag.handle(.drag(x: 400), width: w340)
        #expect(
            drag.handle(.escape, width: HeaderWidth(402)) == PaneDragStep(width: w340, save: false),
            "Esc gives the start width")
        #expect(!drag.isActive)
        #expect(drag.handle(.up, width: w340) == nil, "Esc gives the start width")
    }

    @Test mutating func idleEventsAreNotTaken() {
        #expect(drag.handle(.escape, width: w340) == nil, "Esc when idle is not taken")
        #expect(drag.handle(.drag(x: 400), width: w340) == nil, "Esc when idle is not taken")
        #expect(drag.handle(.up, width: w340) == nil, "Esc when idle is not taken")
    }

    @Test mutating func aDoubleClickGivesTheStandardWidth() {
        _ = drag.handle(.down(x: 418, clicks: 1), width: HeaderWidth(420))
        _ = drag.handle(.up, width: HeaderWidth(420))
        #expect(
            drag.handle(.down(x: 418, clicks: 2), width: HeaderWidth(420)) == PaneDragStep(width: w340, save: true),
            "double-click gives 340")
        #expect(!drag.isActive, "double-click gives 340")
        #expect(drag.handle(.drag(x: 300), width: w340) == nil, "double-click gives 340")
    }
}
