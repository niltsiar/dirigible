import DirigibleCore
import Testing

@testable import DirigibleTimeline

/// Marquee select (decisions 0038 and 0020): a Shift-drag on the lanes selects the clips that the
/// rectangle holds whole. The small fixture: 480 frames per point, 60 pt lanes. On t1, A is x 100 to
/// 200 pt and B x 300 to 400 pt; on t2, C is x 100 to 200 pt; t3 is empty and the lanes end at y 180.
struct MarqueeGestureTests {
    var session: Session
    var selection = Selection.none
    var canEdit = true
    var snaps = false
    var gesture = TimelineGesture()

    init() throws { session = try Fixture.session() }

    var context: GestureContext {
        GestureContext(
            session: session, selection: selection, playhead: 0, geometry: Fixture.geometry, canEdit: canEdit,
            canRipple: true, snaps: snaps)
    }

    static func clips(_ ids: ClipID...) -> GestureEffect { .selection(.clips(ClipSet(Set(ids))!)) }

    mutating func down(_ x: Double, _ y: Double, command: Bool = false, option: Bool = false) {
        _ = gesture.handle(.down(.lanes(x: x, y: y), shift: true, command: command, option: option), context)
    }

    mutating func drag(_ x: Double, _ y: Double) -> [GestureEffect] {
        gesture.handle(.drag(.lanes(x: x, y: y)), context)
    }

    mutating func up(_ x: Double, _ y: Double) -> [GestureEffect] { gesture.handle(.up(.lanes(x: x, y: y)), context) }

    /// A marquee from `from` to `to`: the effects of its one drag event.
    mutating func marquee(from: (Double, Double), to: (Double, Double)) -> [GestureEffect] {
        down(from.0, from.1)
        return drag(to.0, to.1)
    }

    @Test mutating func aShiftDragSelectsTheClipsThatItHoldsWhole() {
        #expect(marquee(from: (90, 30), to: (200, 90)) == [Self.clips("A", "C")])
        #expect(gesture.drawn(session) == session)
        #expect(up(200, 90) == [Self.clips("A", "C")], "no seek and no commit at the up")
        #expect(!gesture.isActive)
        #expect(marquee(from: (200, 90), to: (90, 30)) == [Self.clips("A", "C")], "a drag in the other direction")
    }

    @Test mutating func aClipEdgeOnTheMarqueeIsInAndOneFrameShortIsOut() {
        #expect(marquee(from: (90, 30), to: (200, 90)) == [Self.clips("A", "C")], "the end of A at the pointer")
        #expect(drag(199.99, 90) == [.selection(.none)], "frame 95,995")
        _ = up(199.99, 90)
        #expect(marquee(from: (100, 30), to: (210, 30)) == [Self.clips("A")], "the start of A at the press")
        _ = up(210, 30)
        #expect(marquee(from: (100.01, 30), to: (210, 30)) == [.selection(.none)], "frame 48,004")
    }

    @Test mutating func aLaneJoinsWhenThePointerReachesIt() {
        #expect(marquee(from: (90, 30), to: (210, 60)) == [Self.clips("A", "C")])
        #expect(drag(210, 59.99) == [Self.clips("A")])
    }

    @Test mutating func aMarqueeWithNoClipGivesNoSelection() {
        selection = .clips(ClipSet("B"))
        #expect(marquee(from: (210, 150), to: (290, 170)) == [.selection(.none)])
        #expect(up(290, 170) == [.selection(.none)])
    }

    @Test mutating func aMarqueeReplacesTheSelectionAtTheDown() {
        selection = .clips(ClipSet("B"))
        #expect(marquee(from: (90, 30), to: (200, 90)) == [Self.clips("A", "C")])
        _ = up(200, 90)
        selection = .range(Marks(inPoint: 0, outPoint: 1000, tracks: ["t2"]))
        #expect(marquee(from: (90, 30), to: (200, 90)) == [Self.clips("A", "C")])
    }

    @Test mutating func aShiftCommandDragStaysTheRangeDrag() {
        selection = .range(Marks(inPoint: 0, outPoint: 1000, tracks: ["t2"]))
        down(90, 30, command: true)
        #expect(drag(250, 30) == [.marks(Marks(inPoint: 0, outPoint: 120_000, tracks: ["t1", "t2"]))])
        #expect(gesture.marquee == nil)
    }

    /// From the set of A (48,000 ..< 96,000 on t1), a Shift-Command drag on the lanes from the lower part
    /// of A to 120,000 extends the span of the set: the range runs from the first clip start (decision 0038).
    @Test mutating func aShiftCommandDragFromAClipSetExtendsItsSpan() {
        selection = .clips(ClipSet("A"))
        down(150, 50, command: true)
        #expect(drag(250, 50) == [.marks(Marks(inPoint: 48_000, outPoint: 120_000, tracks: ["t1"]))])
        #expect(gesture.marquee == nil)
    }

    /// The upper part of a clip of the set slips (decision 0020): the press of
    /// `aShiftCommandDragFromAClipSetExtendsItsSpan` at y 30 makes no range.
    @Test mutating func aShiftCommandDragOnTheUpperPartOfASetClipSlips() {
        selection = .clips(ClipSet("A"))
        down(150, 30, command: true)
        // A sits at offset 0, so its content slips only to the left.
        #expect(drag(100, 30) == [])
        #expect(gesture.drawn(session).clip("A")?.clip.offset == 24_000)
        #expect(gesture.marquee == nil)
    }

    @Test mutating func aShiftDragFromBelowTheLastLaneChangesNothing() {
        #expect(marquee(from: (150, 200), to: (300, 50)) == [])
        #expect(up(300, 50) == [])
        down(150, 200, command: true)
        #expect(drag(300, 50) == [], "Shift-Command below the last lane")
    }

    @Test mutating func optionShiftDrawsTheMarquee() {
        down(90, 30, option: true)
        #expect(drag(200, 90) == [Self.clips("A", "C")])
        #expect(gesture.drawn(session) == session, "no trim")
        _ = up(200, 90)
        guard case .trim = Fixture.geometry.hit(100, 10, in: session) else {
            Issue.record("x 100, y 10 is not the trim zone of A")
            return
        }
        down(100, 10, option: true)
        #expect(drag(210, 100) == [Self.clips("A", "C")], "from the trim zone of A")
    }

    @Test mutating func escapeATakeAndASessionChange() throws {
        selection = .clips(ClipSet("B"))
        _ = marquee(from: (90, 30), to: (200, 90))
        #expect(gesture.handle(.escape, context) == [.selection(.clips(ClipSet("B")))])
        #expect(drag(210, 90) == [] && up(210, 90) == [] && !gesture.isActive)

        canEdit = false
        #expect(marquee(from: (90, 30), to: (200, 90)) == [Self.clips("A", "C")], "a take does not stop it")
        _ = up(200, 90)
        canEdit = true

        _ = marquee(from: (90, 30), to: (200, 90))
        try session.removeClips(["A"])
        _ = gesture.handle(.sessionChanged, context)
        #expect(drag(201, 90) == [Self.clips("C")])
    }

    @Test mutating func theMarqueeHasARectangleAnArrowAndNoSnap() {
        snaps = true
        down(90, 30)
        #expect(gesture.marquee == nil)
        _ = drag(91, 31)
        #expect(gesture.marquee == nil, "under 3 pt of movement")
        _ = drag(200, 90)
        #expect(gesture.marquee == Rect(x: 90, y: 30, width: 110, height: 60))
        #expect(gesture.cursor(at: .lanes(x: 200, y: 90), context) == .arrow && gesture.autoscrolls)
        _ = drag(90, 30)
        #expect(gesture.marquee == Rect(x: 90, y: 30, width: 0, height: 0))
        _ = drag(40, 100)
        #expect(gesture.marquee == Rect(x: 40, y: 30, width: 50, height: 70), "left of the press")

        #expect(drag(398, 30) == [Self.clips("A")], "2 pt before the end of B: B is not whole, and nothing snaps")
        #expect(gesture.guide == nil)
        _ = up(398, 30)
        #expect(gesture.marquee == nil)
        _ = marquee(from: (90, 30), to: (200, 90))
        _ = gesture.handle(.escape, context)
        #expect(gesture.marquee == nil)
    }
}
