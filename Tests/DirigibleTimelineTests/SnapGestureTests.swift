import DirigibleCore
import Testing

@testable import DirigibleTimeline

/// The snap step of the gesture (snap run, criteria C1, C2, C4 to C8): the small fixture (480
/// frames per point, 60 pt lanes). On t1, A is x 100 to 200 pt and B x 300 to 400 pt; on t2, C is x
/// 100 to 200 pt. The move zone of lane 0 is y 0 to 40 pt, the range zone y 40 to 60 pt. The snap
/// reach is 6 pt.
struct SnapGestureTests {
    var session: Session
    var selection = Selection.none
    var playhead = Frames(1_000_000)
    var snaps = true
    var gesture = TimelineGesture()

    init() throws { session = try Fixture.session() }

    static func frame(_ x: Double) -> Frames { Frames(Int(x * 480)) }

    var context: GestureContext {
        GestureContext(
            session: session, selection: selection, playhead: playhead, geometry: Fixture.geometry, canEdit: true,
            canRipple: true, snaps: snaps)
    }

    mutating func down(_ x: Double, _ y: Double, shift: Bool = false, option: Bool = false) {
        _ = gesture.handle(.down(.lanes(x: x, y: y), shift: shift, command: false, option: option), context)
    }

    mutating func drag(_ x: Double, _ y: Double) -> [GestureEffect] {
        gesture.handle(.drag(.lanes(x: x, y: y)), context)
    }

    mutating func up(_ x: Double, _ y: Double) -> [GestureEffect] { gesture.handle(.up(.lanes(x: x, y: y)), context) }

    func range(_ id: ClipID, in session: Session? = nil) -> Range<Frames>? {
        (session ?? gesture.drawn(self.session)).clip(id)?.clip.range
    }

    func committed(_ effects: [GestureEffect]) -> Session? {
        guard
            let commit = effects.lazy.compactMap({ effect -> GestureCommit? in
                if case .commit(let commit) = effect { return commit }
                return nil
            }).first
        else { return nil }
        var result = session
        return commit.apply(to: &result) ? result : nil
    }

    @Test mutating func aMoveSnapsItsNearerEdge() throws {
        // B start 5 pt from the end of A (x 200) snaps; 7 pt does not.
        down(350, 10)
        _ = drag(255, 10)
        #expect(range("B") == 96_000..<144_000)
        _ = drag(257, 10)
        #expect(range("B") == Self.frame(207)..<Self.frame(307))
        _ = drag(255, 10)
        let moved = committed(up(255, 10))
        #expect(range("B", in: moved) == 96_000..<144_000, "the commit has the snapped start")
        // The playhead is 2 pt from the start of B, a marker 1 pt from its end: the nearer wins.
        playhead = Self.frame(305)
        try session.setMarker(Marker(id: "m", name: "M", position: Self.frame(404), kind: .marker))
        down(350, 10)
        _ = drag(353, 10)
        #expect(range("B") == Self.frame(304)..<Self.frame(404))
    }

    @Test mutating func aClickJitterNeverSnaps() {
        // The playhead is 1 pt from the start of B; 2 pt of horizontal movement is under the threshold.
        playhead = Self.frame(301)
        down(350, 10)
        _ = drag(352, 13)
        #expect(range("B") == 144_000..<192_000)
        let effects = up(352, 13)
        #expect(committed(effects) == nil)
        #expect(effects == [.clip("B")])
    }

    @Test mutating func aTrimSnapsInsideItsLimits() throws {
        session = try Fixture.session(withB: false)
        // The end of A (x 200) dragged 16 pt right is 4 pt from the playhead at x 220.
        playhead = Self.frame(220)
        down(198, 10)
        _ = drag(214, 10)
        #expect(range("A") == 48_000..<Self.frame(220))
        #expect(gesture.guide == Self.frame(220))
        _ = up(214, 10)
        // A target past the file end (x 400) gives the limit and no guide.
        playhead = Self.frame(403)
        down(198, 10)
        _ = drag(397, 10)
        #expect(range("A") == 48_000..<192_000)
        #expect(gesture.guide == nil)
        _ = up(397, 10)
        // A start-edge trim of B (offset 48,000) snaps to the playhead 4 pt away.
        session = try Fixture.session()
        playhead = Self.frame(290)
        down(302, 10)
        _ = drag(296, 10)
        #expect(range("B") == Self.frame(290)..<192_000)
        _ = up(296, 10)
        // The trimmed clip gives no target: a start-edge drag near its own end does not stop there.
    }

    @Test mutating func aRippleTrimDoesNotSnap() throws {
        session = try Fixture.session(withB: false)
        playhead = Self.frame(220)
        down(198, 10, option: true)
        _ = drag(214, 10)
        #expect(range("A") == 48_000..<Self.frame(216))
        #expect(gesture.guide == nil)
    }

    @Test mutating func aRangeDragSnapsItsPointerEnd() throws {
        try session.setMarker(Marker(id: "m", name: "M", position: Self.frame(320), kind: .chapter))
        // The press end stays at the press frame; the pointer end 4 pt from the marker snaps.
        playhead = Self.frame(252)
        down(250, 50)
        let effects = drag(316, 50)
        #expect(effects == [.selection(.range(Marks(inPoint: 120_000, outPoint: Self.frame(320), tracks: ["t1"])))])
        #expect(gesture.guide == Self.frame(320))
        _ = up(316, 50)
        // A Shift-drag on the lanes draws a marquee, which never snaps (decision 0038).
        selection = .range(Marks(inPoint: 48_000, outPoint: 96_000, tracks: ["t1"]))
        down(250, 50, shift: true)
        #expect(drag(316, 50) == [.selection(.none)])
        #expect(gesture.guide == nil)
    }

    /// C14: a lane range drag from the playhead frame has no playhead target, so 3 pt makes a range,
    /// also after a session change. With the playhead at another frame at the down, the end snaps to it.
    @Test mutating func aRangeDragFromThePlayheadHasNoPlayheadTarget() throws {
        playhead = Self.frame(250)
        down(250, 50)
        #expect(
            drag(253, 50) == [.selection(.range(Marks(inPoint: 120_000, outPoint: Self.frame(253), tracks: ["t1"])))])
        _ = gesture.handle(.sessionChanged, context)
        #expect(
            drag(253, 50) == [.selection(.range(Marks(inPoint: 120_000, outPoint: Self.frame(253), tracks: ["t1"])))],
            "the rebuild keeps the flag of the down")
        _ = up(253, 50)

        playhead = Self.frame(257)
        down(250, 50)
        #expect(
            drag(253, 50) == [.selection(.range(Marks(inPoint: 120_000, outPoint: Self.frame(257), tracks: ["t1"])))],
            "the playhead 4 pt from the end")
        #expect(gesture.guide == Self.frame(257))
    }

    /// Plan gate 1 item 2: a vertical range drag across lanes keeps the raw frames, also with a
    /// target 1 pt from the press.
    @Test mutating func aVerticalRangeDragNeverSnaps() {
        playhead = Self.frame(251)
        down(250, 50)
        let effects = drag(251.5, 110)
        #expect(
            effects == [.selection(.range(Marks(inPoint: 120_000, outPoint: Self.frame(251.5), tracks: ["t1", "t2"])))])
        #expect(gesture.guide == nil)
    }

    /// Code gate item 2: a session change (an undo, a take) during a range drag gives the targets of
    /// the new session, so the pointer end never stops at a clip edge that is gone.
    @Test mutating func aRangeDragAfterASessionChangeSnapsToTheNewEdges() throws {
        down(250, 50)
        _ = drag(297, 50)
        #expect(gesture.guide == Self.frame(300), "the start of B")
        session = try Fixture.session(withB: false)
        _ = gesture.handle(.sessionChanged, context)
        let effects = drag(297, 50)
        #expect(effects == [.selection(.range(Marks(inPoint: 120_000, outPoint: Self.frame(297), tracks: ["t1"])))])
        #expect(gesture.guide == nil)
    }

    @Test mutating func aGroupSnapsByTheClipUnderThePointer() throws {
        // A, B, and C move together. The playhead is 2 pt from the moved end of B; a marker 1 pt from
        // the moved end of A. Only B, the clip under the pointer, snaps.
        selection = ClipSet(["A", "B", "C"]).map { .clips($0) } ?? .none
        playhead = Self.frame(405)
        try session.setMarker(Marker(id: "m", name: "M", position: Self.frame(204), kind: .marker))
        down(350, 10)
        _ = drag(353, 10)
        #expect(range("B") == Self.frame(305)..<Self.frame(405))
        #expect(range("A") == Self.frame(105)..<Self.frame(205))
        #expect(gesture.guide == Self.frame(405))
    }

    @Test mutating func snapOffGivesTheRawPosition() throws {
        snaps = false
        down(350, 10)
        _ = drag(255, 10)
        #expect(range("B") == Self.frame(205)..<Self.frame(305), "a move")
        _ = up(255, 10)
        session = try Fixture.session(withB: false)
        playhead = Self.frame(220)
        down(198, 10)
        _ = drag(214, 10)
        #expect(range("A") == 48_000..<Self.frame(216), "a trim")
        _ = up(214, 10)
        down(250, 50)
        #expect(
            drag(217, 50) == [.selection(.range(Marks(inPoint: Self.frame(217), outPoint: 120_000, tracks: ["t1"])))])
        _ = up(217, 50)
        session = try Fixture.session()
        selection = ClipSet(["A", "B"]).map { .clips($0) } ?? .none
        playhead = Self.frame(405)
        down(350, 10)
        _ = drag(353, 10)
        #expect(range("B") == Self.frame(303)..<Self.frame(403), "a group")
        #expect(gesture.guide == nil)
    }

    @Test mutating func theGuideFollowsTheSnap() throws {
        down(350, 10)
        #expect(gesture.guide == nil)
        _ = drag(255, 10)
        #expect(gesture.guide == 96_000)
        _ = drag(257, 10)
        #expect(gesture.guide == nil, "out of reach")
        _ = drag(255, 10)
        #expect(gesture.guide == 96_000)
        _ = gesture.handle(.escape, context)
        #expect(gesture.guide == nil, "Esc")
        _ = up(255, 10)
        down(350, 10)
        _ = drag(255, 10)
        _ = gesture.handle(.sessionChanged, context)
        #expect(gesture.guide == nil, "a session change")
        _ = up(255, 10)
        down(350, 10)
        _ = drag(255, 10)
        _ = up(255, 10)
        #expect(gesture.guide == nil, "the up")
    }

    /// The state after a commit: a new drag starts with no guide and snaps again.
    @Test mutating func aSecondDragAfterASnappedCommitSnapsAgain() throws {
        down(350, 10)
        _ = drag(255, 10)
        session = try #require(committed(up(255, 10)))
        #expect(range("B", in: session) == 96_000..<144_000)
        // B is now x 200 to 300; its end 4 pt from a marker at x 404 after a 100 pt move.
        try session.setMarker(Marker(id: "m", name: "M", position: Self.frame(404), kind: .marker))
        down(250, 10)
        #expect(gesture.guide == nil)
        _ = drag(350, 10)
        #expect(range("B") == Self.frame(304)..<Self.frame(404))
        #expect(gesture.guide == Self.frame(404))
    }
}
