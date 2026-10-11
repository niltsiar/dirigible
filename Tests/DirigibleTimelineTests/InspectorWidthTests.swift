import Testing

@testable import DirigibleTimeline

/// Run ui-polish-chrome criteria C10 and C11: the inspector width clamps to 240...400 pt, rounds to
/// whole points, and shares the drag of the header handle (double-click, Esc, save at the up).
struct InspectorWidthTests {
    @Test func theWidthClampsAndRounds() {
        #expect(InspectorWidth(239).points == 240, "clamp")
        #expect(InspectorWidth(240).points == 240, "clamp")
        #expect(InspectorWidth(240.4).points == 240, "rounds to whole points")
        #expect(InspectorWidth(300).points == 300)
        #expect(InspectorWidth(400).points == 400, "clamp")
        #expect(InspectorWidth(401).points == 400, "clamp")
        #expect(InspectorWidth(-5).points == 240, "clamp")
        #expect(InspectorWidth(.nan).points == 270, "NaN gives the standard width")
        #expect(InspectorWidth.standard.points == 270)
    }

    /// 0024 P11: the key and its value type never change. A missing key or a text gives 270 pt.
    @Test func theKeyIsFrozenAndAStoredValueClamps() {
        #expect(InspectorWidth.defaultsKey == "view.inspector.width", "frozen key")
        #expect(InspectorWidth(stored: nil) == .standard)
        #expect(InspectorWidth(stored: "320") == .standard)
        #expect(InspectorWidth(stored: 320.0).points == 320)
        #expect(InspectorWidth(stored: 1000.0).points == 400)
        #expect(InspectorWidth(stored: -5.0).points == 240)
    }

    /// The inspector grows to the left, so its handle sends minus the window x: the width is the
    /// start width minus the pointer move.
    @Test func aDragDoubleClickAndEscWorkAsForTheHeader() {
        var drag = PaneDrag<InspectorWidth>()
        let start = InspectorWidth(300)
        _ = drag.handle(.down(x: -910, clicks: 1), width: start)
        #expect(drag.handle(.drag(x: -860), width: start) == PaneDragStep(width: InspectorWidth(350), save: false))
        #expect(drag.handle(.drag(x: -500), width: start)?.width.points == 400, "clamp")
        #expect(drag.handle(.escape, width: InspectorWidth(400)) == PaneDragStep(width: start, save: false), "Esc")
        _ = drag.handle(.down(x: -910, clicks: 1), width: start)
        #expect(drag.handle(.drag(x: -940), width: start)?.width.points == 270)
        #expect(drag.handle(.up, width: InspectorWidth(270)) == PaneDragStep(width: InspectorWidth(270), save: true))
        #expect(
            drag.handle(.down(x: -910, clicks: 2), width: InspectorWidth(380))
                == PaneDragStep(width: .standard, save: true), "double-click gives 270")
    }
}
