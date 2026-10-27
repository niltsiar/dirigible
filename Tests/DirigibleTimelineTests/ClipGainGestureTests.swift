import DirigibleCore
import Testing

@testable import DirigibleTimeline

/// Criteria D1 to D9 of run 11b-1: the gain drag, the fade-handle drag, and the double-click
/// resets on the small fixture (480 frames per point, 60 pt lanes, so 1 dB per pt; A is x 100 to
/// 200 pt on lane 0; at 0 dB its gain band is y 0 to 6, and its handles are x 100 to 108 and 192
/// to 200, y 0 to 8).
struct ClipGainGestureTests {
    var session: Session
    var gesture = TimelineGesture()
    /// The Marks of the clip range of A.
    let marksOnA = Marks(inPoint: 48_000, outPoint: 96_000, tracks: ["t1"])
    let setOfA = Selection.clips(ClipSet("A"))

    init() throws { session = try Fixture.session() }

    func context(marks: Marks = Marks(), canEdit: Bool = true) -> GestureContext {
        GestureContext(
            session: session, selection: .range(marks), playhead: 1000, geometry: Fixture.geometry, canEdit: canEdit,
            canRipple: true, snaps: false)
    }

    mutating func down(_ x: Double, _ y: Double, clicks: Int = 1, marks: Marks = Marks()) {
        let effects = gesture.handle(
            .down(.lanes(x: x, y: y), shift: false, command: false, clicks: clicks), context(marks: marks))
        precondition(effects.isEmpty)
    }

    mutating func drag(_ x: Double, _ y: Double, canEdit: Bool = true) -> [GestureEffect] {
        gesture.handle(.drag(.lanes(x: x, y: y)), context(canEdit: canEdit))
    }

    mutating func up(_ x: Double, _ y: Double, canEdit: Bool = true) -> [GestureEffect] {
        gesture.handle(.up(.lanes(x: x, y: y)), context(canEdit: canEdit))
    }

    var a: Clip { session.clip("A")!.clip }
    func drawnA() -> Clip { gesture.drawn(session).clip("A")!.clip }

    /// The session after the one commit of `effects`, or nil when there is none.
    func committed(_ effects: [GestureEffect]) -> Session? {
        guard effects.count == 1, case .commit(let commit) = effects[0] else { return nil }
        var result = session
        return commit.apply(to: &result) ? result : nil
    }

    func commitSelection(_ effects: [GestureEffect]) -> Selection? {
        guard effects.count == 1, case .commit(let commit) = effects[0] else { return nil }
        return commit.selection
    }

    mutating func setA(gain: Double = 0, fades: Fades = .zero) throws {
        try session.setGain(Gain(dB: gain)!, clip: "A")
        try session.setFades(["A": fades])
    }

    @Test mutating func gainDragSetsOneClipFromEachSelection() throws {
        for marks in [Marks(), marksOnA, Marks(inPoint: 48_000, outPoint: 96_000, tracks: ["t2"])] {
            down(150, 2, marks: marks)
            #expect(drag(150, 8) == [])
            #expect(drawnA().gain == Gain(dB: -6), "the preview")
            let effects = up(150, 8)
            let result = try #require(committed(effects))
            #expect(result.clip("A")?.clip.gain == Gain(dB: -6))
            #expect(result.clip("C")?.clip.gain == .zero, "C keeps its gain")
            #expect(commitSelection(effects) == setOfA)
        }
    }

    /// C15: each clip edit of this file's gestures selects the edited clip as a set of one clip.
    @Test mutating func aClipEditCommitSelectsTheEditedClip() throws {
        down(150, 2)
        _ = drag(150, 8)
        #expect(commitSelection(up(150, 8)) == setOfA, "a gain drag")
        down(104, 4)
        _ = drag(150, 4)
        #expect(commitSelection(up(150, 4)) == setOfA, "a fade drag")

        try setA(gain: -6)
        down(150, 8, clicks: 2)
        #expect(commitSelection(up(150, 8)) == setOfA, "a double-click reset")

        // The points at x 125, 150, and 175; the line at x 150 is at y 8, at x 140 it is at y 4.8.
        try setA()
        try session.setEnvelope([60_000: Gain(dB: 0)!, 72_000: Gain(dB: -8)!, 84_000: Gain(dB: 0)!], clip: "A")
        down(150, 8)
        _ = drag(160, 14)
        #expect(commitSelection(up(160, 14)) == setOfA, "a point drag")
        _ = gesture.handle(.down(.lanes(x: 140, y: 4.8), shift: false, command: false, option: true), context())
        #expect(commitSelection(up(140, 4.8)) == setOfA, "an Option press that adds a point")
        down(150, 8, clicks: 2)
        #expect(commitSelection(up(150, 8)) == setOfA, "a double-click that removes a point")
    }

    @Test mutating func gainDragRoundsToATenthOfADecibel() {
        down(150, 2)
        _ = drag(150, 7.56)
        #expect(drawnA().gain == Gain(dB: -5.6))
        _ = drag(150, 7.54)
        #expect(drawnA().gain == Gain(dB: -5.5))
        _ = up(150, 7.54)

        down(150, 2)
        #expect(up(150, 4.9) == [.clip("A")], "under 3 pt a press is a click")
    }

    @Test mutating func gainDragStopsAtTheLimitsAndKeepsAnOutsideStart() throws {
        down(150, 2)
        _ = drag(150, -28)
        #expect(drawnA().gain == Gain(dB: 20))
        _ = drag(150, 32)
        #expect(drawnA().gain == Gain(dB: -20))
        _ = up(150, 32)

        try setA(gain: -40)
        down(150, 40)
        _ = drag(150, 35)
        #expect(drawnA().gain == Gain(dB: -35))
        _ = drag(150, 45)
        #expect(drawnA().gain == Gain(dB: -40), "not -45 and not -20")
    }

    @Test mutating func fadeHandleDragStopsAtTheOtherFade() throws {
        down(104, 4)
        _ = drag(150, 4)
        #expect(drawnA().fades == Fades(fadeIn: 22_080, fadeOut: 0))
        let result = try #require(committed(up(150, 4)))
        #expect(result.clip("A")?.clip.fades == Fades(fadeIn: 22_080, fadeOut: 0))

        try setA(fades: Fades(fadeIn: 0, fadeOut: 24_000)!)
        down(104, 4)
        _ = drag(190, 4)
        #expect(drawnA().fades == Fades(fadeIn: 24_000, fadeOut: 24_000), "not 24,001")
        _ = drag(50, 4)
        #expect(drawnA().fades == Fades(fadeIn: 0, fadeOut: 24_000), "left of the clip start")
    }

    /// Crossfades G10: with a crossfade of 9,600 at the end of A, the fade-in handle stops at the
    /// room of the start, 48,000 - 4,800; no preview reaches a throw.
    @Test mutating func aFadeDragStopsAtTheCrossfade() throws {
        try session.move("B", to: "t1", start: 96_000)
        try session.setCrossfades(["A": 9_600])
        down(104, 4)
        _ = drag(199, 4)
        #expect(drawnA().fades == Fades(fadeIn: 43_200, fadeOut: 0), "the fade-in stops at the crossfade half")
        let result = try #require(committed(up(199, 4)))
        #expect(result.clip("A")?.clip.fades == Fades(fadeIn: 43_200, fadeOut: 0))
        #expect(result.clip("A")?.clip.crossfades == Crossfades(start: 0, end: 9_600), "the crossfade stays")
    }

    @Test mutating func fadeOutHandleDragsFromTheEnd() throws {
        down(196, 4)
        _ = drag(176, 4)
        #expect(drawnA().fades == Fades(fadeIn: 0, fadeOut: 9_600))
        let effects = up(176, 4)
        #expect(try #require(committed(effects)).clip("A")?.clip.fades == Fades(fadeIn: 0, fadeOut: 9_600))
        #expect(commitSelection(effects) == setOfA)
    }

    @Test mutating func escapeDropsAGainOrFadeDrag() {
        for (from, to) in [((150.0, 2.0), (150.0, 8.0)), ((104, 4), (150, 4))] {
            down(from.0, from.1)
            _ = drag(to.0, to.1)
            #expect(gesture.drawn(session) != session, "the drag reached the preview")
            #expect(gesture.handle(.escape, context()) == [])
            #expect(gesture.drawn(session) == session)
            #expect(up(to.0, to.1) == [])
        }
    }

    @Test mutating func aTakeOrASessionChangeDropsTheDrag() {
        down(150, 2)
        #expect(drag(150, 8, canEdit: false) == [])
        #expect(gesture.drawn(session) == session, "no preview during a take")
        #expect(up(150, 8, canEdit: false) == [.clip("A")])

        for (from, to) in [((150.0, 2.0), (150.0, 8.0)), ((104, 4), (150, 4))] {
            down(from.0, from.1)
            _ = drag(to.0, to.1)
            #expect(gesture.drawn(session) != session, "the drag reached the preview")
            #expect(gesture.handle(.sessionChanged, context()) == [])
            #expect(up(to.0, to.1) == [])
        }
    }

    @Test mutating func aDoubleClickResetsTheGainOrTheFade() throws {
        try setA(gain: -6)
        down(150, 8, clicks: 2)
        #expect(try #require(committed(up(150, 8))).clip("A")?.clip.gain == .zero)

        try setA(gain: 0)
        down(150, 2, clicks: 2)
        #expect(up(150, 2) == [.clip("A")], "no change, no commit")

        try setA(fades: Fades(fadeIn: 4_800, fadeOut: 960)!)
        down(110, 4, clicks: 2)
        #expect(try #require(committed(up(110, 4))).clip("A")?.clip.fades == Fades(fadeIn: 0, fadeOut: 960))

        try setA(fades: Fades(fadeIn: 0, fadeOut: 960)!)
        down(104, 4, clicks: 2)
        #expect(up(104, 4) == [.clip("A")], "no fade-in, no commit")

        try setA(gain: -6)
        down(150, 8, clicks: 2)
        #expect(up(150, 8, canEdit: false) == [.clip("A")], "no commit during a take")
    }

    @Test mutating func theReadoutFollowsTheDrag() {
        #expect(gesture.readout == nil)
        down(150, 2)
        #expect(gesture.readout == nil, "no drag yet")
        _ = drag(150, 8)
        #expect(gesture.readout == .gain(Gain(dB: -6)!, from: .zero), "the gain and the start gain")
        _ = up(150, 8)
        #expect(gesture.readout == nil)

        down(104, 4)
        _ = drag(150, 4)
        #expect(gesture.readout == .fade(.start, 22_080))
        _ = gesture.handle(.escape, context())
        #expect(gesture.readout == nil)
    }
}
