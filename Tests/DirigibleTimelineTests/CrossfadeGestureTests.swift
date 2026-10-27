import DirigibleCore
import Testing

@testable import DirigibleTimeline

/// Criteria G1 to G6 of run 11c-2: the drag and the double-click of a crossfade handle on the
/// small fixture (480 frames per point, 60 pt lanes) with B at 96,000, so A (x 100 to 200) and B
/// (x 200 to 300) join at x 200. The crossfade of 19,200 frames has 20 pt on each side: A's handle
/// is x 176 to 184, and B's handle is x 216 to 224, y 0 to 8. The limit is 96,000 (the room of
/// each clip and the handles are 48,000).
struct CrossfadeGestureTests {
    var session: Session
    var gesture = TimelineGesture()

    init() throws {
        session = try Fixture.session()
        try session.move("B", to: "t1", start: 96_000)
        try session.setCrossfades(["A": 19_200])
    }

    func context(canEdit: Bool = true) -> GestureContext {
        GestureContext(
            session: session, selection: .none, playhead: 0, geometry: Fixture.geometry, canEdit: canEdit,
            canRipple: true, snaps: false)
    }

    mutating func down(_ x: Double, clicks: Int = 1, shift: Bool = false) {
        let effects = gesture.handle(
            .down(.lanes(x: x, y: 2), shift: shift, command: false, clicks: clicks), context())
        precondition(effects.isEmpty)
    }

    mutating func drag(_ x: Double, canEdit: Bool = true) -> [GestureEffect] {
        gesture.handle(.drag(.lanes(x: x, y: 2)), context(canEdit: canEdit))
    }

    mutating func up(_ x: Double) -> [GestureEffect] { gesture.handle(.up(.lanes(x: x, y: 2)), context()) }

    /// The crossfades of A and B in the drawn session.
    var drawn: (a: Crossfades?, b: Crossfades?) {
        let session = gesture.drawn(session)
        return (session.clip("A")?.clip.crossfades, session.clip("B")?.clip.crossfades)
    }

    /// The session after the one commit of `effects`, or nil when there is none.
    func committed(_ effects: [GestureEffect]) -> Session? {
        guard effects.count == 1, case .commit(let commit) = effects[0] else { return nil }
        var result = session
        return commit.apply(to: &result) ? result : nil
    }

    /// G1: 10 pt left on A's handle adds 2 x 4,800 frames, in one commit. The drag is relative to
    /// the press: a press 3 pt right of the handle center gives the same length (fail value of the
    /// absolute form, 2 x (J - x): 25,920).
    @Test mutating func aDragOfTheLeftHandleMakesTheCrossfadeLonger() throws {
        down(180)
        #expect(drag(170) == [])
        #expect(drawn.a == Crossfades(start: 0, end: 28_800) && drawn.b == Crossfades(start: 28_800, end: 0))
        #expect(gesture.readout == .crossfade(28_800))
        let result = try #require(committed(up(170)))
        #expect(result.clip("A")?.clip.crossfades.end == 28_800 && result.clip("B")?.clip.crossfades.start == 28_800)

        down(183)
        _ = drag(173)
        #expect(drawn.a?.end == 28_800, "press-relative")
    }

    /// G1: B's handle makes the crossfade longer to the right and shorter to the left.
    @Test mutating func aDragOfTheRightHandleMirrorsTheLeftHandle() {
        down(220)
        _ = drag(230)
        #expect(drawn.a?.end == 28_800)
        _ = drag(210)
        #expect(drawn.a?.end == 9_600)
    }

    /// G2: a drag past the limit stops at the limit (fail value: 96,002), and the readout shows it.
    @Test mutating func aDragStopsAtTheLimit() {
        down(180)
        _ = drag(0)
        #expect(drawn.a?.end == 96_000)
        #expect(gesture.readout == .crossfade(96_000))
    }

    /// C35: at a seamless join with two gains (B plays on in fa at -6 dB), the drag clamps to the
    /// handle limit of a butt join, 96,000. Fail value of the old limit 0: 0.
    @Test mutating func aDragAtASeamlessJoinStopsAtTheHandleLimit() throws {
        session = try Fixture.session(withB: false)
        try session.place(
            Clip(id: "B", file: "fa", start: 96_000, offset: 48_000, length: 48_000, gain: Gain(dB: -6)!), on: "t1")
        try session.setCrossfades(["A": 19_200])
        down(180)
        _ = drag(170)
        #expect(drawn.a == Crossfades(start: 0, end: 28_800) && drawn.b == Crossfades(start: 28_800, end: 0))
        _ = drag(0)
        #expect(drawn.a?.end == 96_000 && gesture.readout == .crossfade(96_000))
    }

    /// G3: a drag to the join and past it gives 0 on both clips; a drag back out makes the
    /// crossfade again. The commit of 0 removes it, and the handles go away.
    @Test mutating func aDragToTheJoinRemovesTheCrossfade() throws {
        down(180)
        _ = drag(200)
        #expect(drawn.a == .zero && drawn.b == .zero)
        _ = drag(190)
        #expect(drawn.a?.end == 9_600, "back out")
        _ = drag(205)
        #expect(drawn.a == .zero && drawn.b == .zero, "past the join")
        let result = try #require(committed(up(205)))
        #expect(result.clip("A")?.clip.crossfades == .zero && result.clip("B")?.clip.crossfades == .zero)
        let lane = result.tracks[0].clips
        #expect(Fixture.geometry.fadeHandles(of: lane[0], at: 0, in: lane, lane: 0).end == nil)
        #expect(Fixture.geometry.fadeHandles(of: lane[1], at: 1, in: lane, lane: 0).start == nil)
    }

    /// G4: a double-click on either handle removes the crossfade in one commit (fail value: a
    /// click, which sets the Marks).
    @Test mutating func aDoubleClickOnEitherHandleRemovesTheCrossfade() throws {
        for x in [180.0, 220] {
            down(x, clicks: 2)
            let result = try #require(committed(up(x)), "x \(x)")
            #expect(result.clip("A")?.clip.crossfades == .zero && result.clip("B")?.clip.crossfades == .zero)
        }
    }

    /// G5: Shift at the press makes a range press: the drag sets the Marks and no crossfade.
    @Test mutating func shiftMakesARangePress() {
        down(180, shift: true)
        let effects = drag(170)
        #expect(effects.contains { if case .selection = $0 { true } else { false } })
        #expect(drawn.a?.end == 19_200 && gesture.readout == nil)
    }

    /// G6: a take, Esc, or a session change (an Undo or another edit) drops the drag: the up
    /// commits nothing.
    @Test mutating func aTakeEscapeOrASessionChangeDropsTheDrag() {
        down(180)
        _ = drag(170)
        #expect(drag(160, canEdit: false) == [])
        #expect(up(160) == [] && drawn.a?.end == 19_200, "a take")
        for event in [GestureEvent.escape, .sessionChanged] {
            down(180)
            _ = drag(170)
            _ = gesture.handle(event, context())
            #expect(drawn.a?.end == 19_200 && up(170) == [], "\(event)")
        }
    }
}
