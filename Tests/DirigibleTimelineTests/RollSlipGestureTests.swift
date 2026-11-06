import DirigibleCore
import Testing

@testable import DirigibleTimeline

/// The Shift-Command roll and slip drags (decision 0020) on the small fixture (480 frames per
/// point, 60 pt lanes, the upper two thirds above y 40): fixture R adds clip R (file fb) to t1 at
/// 96,000 ..< 144,000 with offset 48,000. A is x 100 to 200 pt, R is x 200 to 300 pt, and they join
/// at x 200. Fixture R9 gives R the offset 9,600.
struct RollSlipGestureTests {
    var session: Session
    var gesture = TimelineGesture()
    var snaps = false
    var playhead = Frames.zero

    init(offset: Frames = 48_000) throws {
        var session = try Fixture.session(withB: false)
        try session.place(Clip(id: "R", file: "fb", start: 96_000, offset: offset, length: 48_000), on: "t1")
        self.session = session
    }

    func context(canEdit: Bool = true) -> GestureContext {
        GestureContext(
            session: session, selection: .none, playhead: playhead, geometry: Fixture.geometry, canEdit: canEdit,
            canRipple: true, snaps: snaps)
    }

    mutating func down(_ x: Double, _ y: Double = 10, shift: Bool = true, command: Bool = true, option: Bool = false) {
        _ = gesture.handle(.down(.lanes(x: x, y: y), shift: shift, command: command, option: option), context())
    }

    @discardableResult
    mutating func drag(_ x: Double, _ y: Double = 10, canEdit: Bool = true) -> [GestureEffect] {
        gesture.handle(.drag(.lanes(x: x, y: y)), context(canEdit: canEdit))
    }

    mutating func up(_ x: Double, _ y: Double = 10, canEdit: Bool = true) -> [GestureEffect] {
        gesture.handle(.up(.lanes(x: x, y: y)), context(canEdit: canEdit))
    }

    var drawn: Session { gesture.drawn(session) }

    func commits(_ effects: [GestureEffect]) -> [GestureCommit] {
        effects.compactMap { if case .commit(let commit) = $0 { commit } else { nil } }
    }

    /// The result of the one commit of `effects`, or nil.
    func committed(_ effects: [GestureEffect]) -> Session? {
        guard let commit = commits(effects).first, commits(effects).count == 1 else { return nil }
        var result = session
        return commit.apply(to: &result) ? result : nil
    }

    func isRange(_ effects: [GestureEffect]) -> Bool {
        guard case .selection(.range)? = effects.first else { return false }
        return effects.count == 1
    }

    @Test mutating func aShiftCommandEdgeDragRolls() throws {
        var expected = session
        try expected.roll("A", by: 24_000)
        down(198)
        drag(248)
        #expect(drawn == expected)
        #expect(drawn.clip("A")?.clip.length == 72_000)
        #expect(drawn.clip("R")?.clip.start == 120_000 && drawn.clip("R")?.clip.offset == 72_000)
        #expect(drawn.clip("R")?.clip.length == 24_000)
        #expect(gesture.autoscrolls, "a roll drag autoscrolls as a trim does (0025)")
        #expect(gesture.cursor(at: .lanes(x: 248, y: 10), context()) == .resizeLeftRight)
        let effects = up(248)
        #expect(commits(effects).count == 1, "one commit, one undo entry")
        #expect(commits(effects).first?.ripple == false)
        #expect(commits(effects).first?.selection == .clips(ClipSet("A")))
        #expect(committed(effects) == expected)
    }

    @Test mutating func aRollFromTheStartZoneOfTheRightClipMovesTheSameJoin() throws {
        var expected = session
        try expected.roll("A", by: 24_000)
        down(202)
        drag(252)
        #expect(drawn == expected)
        #expect(commits(up(252)).first?.selection == .clips(ClipSet("R")), "the clip under the press")
    }

    @Test mutating func aCrossfadeAtTheJoinStillRolls() throws {
        try session.setCrossfades(["A": 960])
        var expected = session
        try expected.roll("A", by: 24_000)
        down(202, 4)
        drag(252, 4)
        #expect(drawn == expected)
    }

    @Test mutating func aRollBackToZeroIsAClick() {
        down(198)
        drag(248)
        drag(198)
        #expect(commits(up(198)).isEmpty)
    }

    @Test mutating func theRollDragStopsAtTheOnePointLength() {
        down(198)
        drag(400)
        #expect(drawn.clip("R")?.clip.length == 480, "R keeps 1 pt")
        #expect(drawn.clip("A")?.clip.length == 95_520)
        drag(50)
        #expect(drawn.clip("A")?.clip.length == 480, "A keeps 1 pt")
        #expect(drawn.clip("R")?.clip.start == 48_480)
        #expect(drawn.clip("R")?.clip.offset == 480)
    }

    @Test mutating func theRollDragStopsAtTheCoreLimit() throws {
        self = try RollSlipGestureTests(offset: 9_600)
        down(198)
        drag(158)
        var expected = session
        try expected.roll("A", by: -9_600)
        #expect(drawn == expected, "a clamp with no rollLimits asks roll for -19,200, which throws")
        #expect(drawn.clip("A")?.clip.length == 38_400 && drawn.clip("R")?.clip.start == 86_400)
        #expect(drawn.clip("R")?.clip.offset == 0)
    }

    @Test mutating func aShiftCommandBodyDragSlips() throws {
        var expected = session
        try expected.slip(["R"], by: -24_000)
        down(250, 30)
        drag(300, 30)
        #expect(drawn == expected)
        #expect(drawn.clip("R")?.clip.offset == 24_000)
        #expect(drawn.clip("R")?.clip.start == 96_000 && drawn.clip("R")?.clip.length == 48_000, "the box stays")
        #expect(!gesture.autoscrolls, "a slip drag does not autoscroll")
        #expect(gesture.cursor(at: .lanes(x: 300, y: 30), context()) == .openHand)
        let effects = up(300, 30)
        #expect(commits(effects).count == 1 && commits(effects).first?.ripple == false)
        #expect(commits(effects).first?.selection == .clips(ClipSet("R")))
        #expect(committed(effects) == expected)
    }

    @Test mutating func theSlipDragStopsAtTheFileEnds() {
        down(250, 30)
        drag(400, 30)
        #expect(drawn.clip("R")?.clip.offset == 0, "a clamp with no slipLimits asks slip for -72,000, which throws")
        drag(100, 30)
        #expect(drawn.clip("R")?.clip.offset == 96_000)
    }

    @Test mutating func aShiftCommandGainBandDragSlips() {
        down(250, 3)
        drag(300, 3)
        #expect(drawn.clip("R")?.clip.offset == 24_000)
    }

    /// A gain band or a shown point in the lower third keeps the range drag and the range cursor.
    @Test mutating func aLowGainBandInTheLowerThirdKeepsTheRangeDrag() throws {
        try session.setGain(#require(Gain(dB: -45)), clip: "R")
        guard case .gain = Fixture.geometry.hit(250, 45, in: session) else {
            Issue.record("x 250, y 45 is not the gain band of R")
            return
        }
        #expect(gesture.cursor(at: .lanes(x: 250, y: 45), context(), shift: true, command: true) == .iBeam)
        down(250, 45)
        #expect(isRange(drag(280, 45)))
        #expect(drawn == session)
    }

    @Test mutating func aLowEnvelopePointInTheLowerThirdKeepsTheRangeDrag() throws {
        try session.setEnvelope([120_000: #require(Gain(dB: -60))], clip: "R")
        let clips = session.tracks[0].clips
        let shown = Fixture.geometry.envelopePoints(of: clips[1], at: 1, in: clips, trackGain: .zero, lane: 0)
        #expect(shown.map(\.x) == [250] && shown.map(\.y) == [57], "the point is clamped to y 57")
        guard case .point = Fixture.geometry.hit(250, 57, in: session) else {
            Issue.record("x 250, y 57 is not the point of R")
            return
        }
        #expect(gesture.cursor(at: .lanes(x: 250, y: 57), context(), shift: true, command: true) == .iBeam)
        down(250, 57)
        #expect(isRange(drag(280, 57)))
        #expect(drawn == session)
    }

    @Test mutating func aShiftCommandDragOnALooseEdgeTrims() {
        snaps = true
        playhead = 120_100
        down(298)
        drag(248)
        #expect(drawn.clip("R")?.clip.range == 96_000..<120_000, "Command holds the snap off")
        #expect(drawn.clip("A")?.clip == session.clip("A")?.clip)
        #expect(gesture.cursor(at: .lanes(x: 248, y: 10), context()) == .resizeLeftRight)
        #expect(commits(up(248)).count == 1)
    }

    @Test mutating func theEdgeZoneWinsOverACornerFadeHandle() throws {
        try session.setFades(["R": #require(Fades(fadeIn: 0, fadeOut: 480))])
        guard case .fade = Fixture.geometry.hit(298, 4, in: session) else {
            Issue.record("x 298, y 4 is not the fade handle of R")
            return
        }
        down(298, 4)
        drag(248, 4)
        #expect(drawn.clip("R")?.clip.range == 96_000..<120_000, "the trim, not a fade or a slip")
        _ = up(248, 4)
        gesture = TimelineGesture()
        down(298, 4, shift: false, command: false)
        drag(248, 4)
        #expect(drawn.clip("R")?.clip.range == session.clip("R")?.clip.range)
        #expect(drawn.clip("R")?.clip.fades != session.clip("R")?.clip.fades, "no keys: the fade handle")
    }

    /// C25: the hover cursor with Shift-Command and no Option follows the zone rule of the press.
    @Test mutating func rollAndSlipCursors() throws {
        func cursor(_ x: Double, _ y: Double, shift: Bool = true, command: Bool = true, option: Bool = false)
            -> TimelineCursor
        {
            gesture.cursor(
                at: .lanes(x: x, y: y), context(), option: option, shift: shift, command: command)
        }
        #expect(cursor(198, 10) == .resizeLeftRight, "the end zone of A")
        #expect(cursor(250, 30) == .openHand, "the upper part of R")
        #expect(cursor(250, 3) == .openHand, "the gain band slips")
        #expect(cursor(250, 50) == .iBeam, "the lower third keeps the range drag")
        #expect(cursor(350, 10) == .iBeam, "a gap")
        #expect(cursor(298, 10) == .resizeLeftRight, "the loose end of R")
        #expect(cursor(250, 3, shift: false, command: false) == .resizeUpDown, "no keys: the gain band")
        #expect(cursor(250, 30, shift: false, command: false) == .arrow, "no keys: the move zone")
        #expect(cursor(250, 30, command: false) == .arrow, "Shift alone")
        #expect(cursor(250, 30, option: true) == .arrow, "Option-Shift-Command is no roll or slip")
        try session.setFades(["R": #require(Fades(fadeIn: 0, fadeOut: 480))])
        guard case .fade = Fixture.geometry.hit(298, 4, in: session) else {
            Issue.record("x 298, y 4 is not the fade handle of R")
            return
        }
        #expect(cursor(298, 4) == .resizeLeftRight, "the edge zone wins over a corner fade handle")
        down(250, 30)
        drag(300, 30)
        #expect(cursor(300, 30, shift: false, command: false) == .openHand, "a slip drag")
        _ = up(300, 30)
        down(198)
        drag(248)
        #expect(cursor(248, 10, shift: false, command: false) == .resizeLeftRight, "a roll drag")
    }

    /// C28: the readout of a roll drag is the move of the join, and it ends with the drag.
    @Test mutating func aRollDragReadoutHoldsTheDelta() {
        down(198)
        #expect(gesture.readout == nil, "no drag yet")
        drag(248)
        #expect(gesture.readout == .roll(24_000))
        drag(188)
        #expect(gesture.readout == .roll(-4_800))
        _ = up(188)
        #expect(gesture.readout == nil, "the mouse-up")
        down(198)
        drag(248)
        _ = gesture.handle(.escape, context())
        #expect(gesture.readout == nil, "Esc")
    }

    /// C28: the readout of a slip drag is the move of the content: a drag to the right is plus.
    @Test mutating func aSlipDragReadoutHoldsTheContentMove() {
        down(250, 30)
        #expect(gesture.readout == nil, "no drag yet")
        drag(300, 30)
        #expect(gesture.readout == .slip(24_000))
        #expect(drawn.clip("R")?.clip.offset == 24_000, "the offset change is minus the readout")
        _ = up(300, 30)
        #expect(gesture.readout == nil, "the mouse-up")
        down(250, 30)
        drag(300, 30)
        _ = gesture.handle(.escape, context())
        #expect(gesture.readout == nil, "Esc")
    }

    @Test mutating func theOtherShiftCommandPressesKeepTheirDrag() {
        down(350, 30)
        #expect(isRange(drag(380, 30)), "a gap")
        #expect(drawn == session)
        gesture = TimelineGesture()
        down(250, 50)
        #expect(isRange(drag(280, 50)), "the lower third of R")
        gesture = TimelineGesture()
        down(250, 30, command: false)
        #expect(drag(280, 30).first == .selection(.none), "Shift alone draws the marquee")
        #expect(gesture.marquee != nil)
        gesture = TimelineGesture()
        down(198, option: true)
        #expect(isRange(drag(248)), "Option-Shift-Command on the end zone of A")
        #expect(drawn == session)
        gesture = TimelineGesture()
        down(250, 30)
        let click = up(250, 30)
        #expect(isRange(click) && commits(click).isEmpty, "a click with no drag is the Shift click of 0017")
    }

    @Test mutating func aBoxUnderTwelvePointsIsAllRange() {
        let narrow = LaneGeometry(scale: TimelineScale(framesPerPoint: 6_000), laneHeight: 60)!
        let context = GestureContext(
            session: session, selection: .none, playhead: 0, geometry: narrow, canEdit: true, canRipple: true,
            snaps: false)
        _ = gesture.handle(.down(.lanes(x: 12, y: 30), shift: true, command: true), context)
        let effects = gesture.handle(.drag(.lanes(x: 20, y: 30)), context)
        #expect(isRange(effects) && gesture.drawn(session) == session)
    }

    @Test mutating func aTakeOrAnEscapeDropsARollDrag() {
        down(198)
        drag(248, canEdit: false)
        #expect(drawn == session, "a take blocks the press")
        #expect(commits(up(248, canEdit: false)).isEmpty)
        down(198)
        drag(248)
        #expect(drawn != session)
        drag(260, canEdit: false)
        #expect(drawn == session, "a take that starts during the drag drops it")
        #expect(up(260).isEmpty)
        down(198)
        drag(248)
        _ = gesture.handle(.escape, context())
        #expect(drawn == session)
        #expect(up(248).isEmpty)
        down(250, 30)
        drag(300, 30)
        _ = gesture.handle(.escape, context())
        #expect(drawn == session && up(300, 30).isEmpty, "Esc drops a slip too")
    }

    @Test mutating func aSessionChangeAfterTheShiftCommandPressDropsIt() {
        down(198)
        _ = gesture.handle(.sessionChanged, context())
        drag(248)
        #expect(drawn == session, "no roll on the old session")
        #expect(up(248).isEmpty)
        down(198)
        drag(248)
        _ = gesture.handle(.sessionChanged, context())
        #expect(drawn == session && up(248).isEmpty, "a session change during the drag")
    }
}
