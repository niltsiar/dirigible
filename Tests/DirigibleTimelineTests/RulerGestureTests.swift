import DirigibleCore
import Testing

@testable import DirigibleTimeline

/// Mouse-edits criteria 11 and 12: the gesture on the ruler of the small fixture (480 frames per
/// point). Marker m1 is at 96,000 (x 200 pt), its flag takes x 197 to 206 pt. The in point is at
/// 48,000 (x 100 pt) and the out point at 192,000 (x 400 pt); the triangles are y 16 to 24 pt.
struct RulerGestureTests {
    let session: Session
    let marks = Marks(inPoint: 48_000, outPoint: 192_000, tracks: ["t1"])
    var gesture = TimelineGesture()
    var selection = Selection.range(Marks(inPoint: 48_000, outPoint: 192_000, tracks: ["t1"]))
    var playhead = Frames(1000)
    var snaps = false

    init() throws {
        var session = try Fixture.session()
        try session.setMarker(Marker(id: "m1", name: "Intro", position: 96_000, kind: .marker))
        self.session = session
    }

    func context(_ session: Session? = nil, canEdit: Bool = true) -> GestureContext {
        var context = GestureContext(
            session: session ?? self.session, selection: selection, playhead: playhead, geometry: Fixture.geometry,
            canEdit: canEdit, canRipple: true)
        context.snaps = snaps
        return context
    }

    mutating func down(_ x: Double, _ y: Double) -> [GestureEffect] {
        gesture.handle(.down(.ruler(x: x, y: y), shift: false, command: false), context())
    }

    mutating func drag(_ x: Double, _ y: Double, canEdit: Bool = true) -> [GestureEffect] {
        gesture.handle(.drag(.ruler(x: x, y: y)), context(canEdit: canEdit))
    }

    mutating func up(_ x: Double, _ y: Double) -> [GestureEffect] {
        gesture.handle(.up(.ruler(x: x, y: y)), context())
    }

    var drawn: Session { gesture.drawn(session) }

    /// The position of m1 in the session after the one commit of `effects`, and the commit.
    func committed(_ effects: [GestureEffect]) -> (position: Frames?, commit: GestureCommit)? {
        guard effects.count == 1, case .commit(let commit) = effects[0] else { return nil }
        var result = session
        return commit.apply(to: &result) ? (result.markers["m1"]?.position, commit) : nil
    }

    /// Criterion 11: a drag of 50 pt moves the flag in the preview; the up makes one commit of
    /// position + 24,000, sets the current marker, and does not seek.
    @Test mutating func aFlagDragCommitsOneSetMarkerAndSetsTheCurrentMarker() {
        #expect(down(201, 10) == [])
        #expect(drag(251, 10) == [])
        #expect(drawn.markers["m1"]?.position == 120_000, "the preview")
        #expect(gesture.cursor(at: .ruler(x: 700, y: 10), context()) == .resizeLeftRight)

        let result = committed(up(251, 10))

        #expect(result?.position == 120_000)
        #expect(result?.commit.marker == "m1" && result?.commit.selection == nil)
        #expect(!gesture.isActive && drawn == session)
    }

    @Test mutating func aFlagClickSelectsAndSeeks() {
        _ = down(201, 10)
        #expect(up(202, 10) == [.currentMarker("m1"), .seek(96_000)])
        _ = down(201, 10)
        _ = drag(251, 10)
        _ = drag(201, 10)
        #expect(up(201, 10) == [.currentMarker("m1"), .seek(96_000)], "the flag went back")
    }

    /// Code gate 1 item 1: the jitter of a click (0.5 pt right, 3 pt down) on a flag or a triangle
    /// moves nothing.
    @Test mutating func aClickWithJitterMovesNoFlagAndNoPoint() {
        _ = down(201, 10)
        #expect(up(201.5, 13) == [.currentMarker("m1"), .seek(96_000)])
        _ = down(100, 20)
        #expect(up(100.5, 23) == [.marks(marks)])
    }

    @Test mutating func aFlagDragStopsAtZero() {
        _ = down(201, 10)
        _ = drag(-300, 10)
        #expect(committed(up(-300, 10))?.position == 0)
    }

    /// Esc, a session change, or a take drop a flag drag: no preview, and the up does nothing.
    @Test mutating func aFlagDragDropsAtEscapeASessionChangeAndATake() throws {
        _ = down(201, 10)
        _ = drag(251, 10)
        #expect(gesture.handle(.escape, context()) == [] && drawn == session)
        #expect(up(251, 10) == [])

        _ = down(201, 10)
        _ = drag(251, 10)
        var changed = session
        try changed.renameTrack("t2", to: "Guest")
        _ = gesture.handle(.sessionChanged, context(changed))
        #expect(drawn == session && up(251, 10) == [], "a session change")

        _ = down(201, 10)
        _ = drag(231, 10)
        #expect(drag(251, 10, canEdit: false) == [] && drawn == session && up(251, 10) == [], "a take")

        _ = down(201, 10)
        _ = drag(251, 10, canEdit: false)
        #expect(drawn == session, "no preview when a take runs at the down")
        let click = gesture.handle(.up(.ruler(x: 251, y: 10)), context(canEdit: false))
        #expect(click == [.currentMarker("m1"), .seek(96_000)], "the up is a click")

        _ = down(201, 10)
        _ = gesture.handle(.sessionChanged, context(changed))
        _ = drag(251, 10)
        #expect(drawn == session && up(251, 10) == [], "a session change between the down and the drag")
    }

    /// Criterion 12: the in point stops 1 frame before the out point, and the out point 1 frame
    /// after the in point; the in point stops at 0.
    @Test mutating func anInTriangleDragStopsBeforeTheOutPoint() {
        _ = down(101, 20)
        #expect(drag(600, 20) == [.marks(Marks(inPoint: 191_999, outPoint: 192_000, tracks: ["t1"]))])
        #expect(drag(-100, 20) == [.marks(Marks(inPoint: 0, outPoint: 192_000, tracks: ["t1"]))])
        _ = up(-100, 20)
        _ = down(399, 20)
        #expect(drag(0, 20) == [.marks(Marks(inPoint: 48_000, outPoint: 48_001, tracks: ["t1"]))])
    }

    /// Criterion 12: a triangle drag changes the Marks only; a click on a triangle seeks to it;
    /// Esc gives back the Marks of the down.
    @Test mutating func aTriangleDragMovesOnlyTheMarks() {
        let moved = [GestureEffect.marks(Marks(inPoint: 72_000, outPoint: 192_000, tracks: ["t1"]))]
        _ = down(101, 20)
        #expect(drag(151, 20) == moved)
        #expect(drawn == session)
        #expect(up(151, 20) == moved)

        _ = down(101, 20)
        #expect(up(101, 20) == [.seek(48_000)], "a click")

        _ = down(101, 20)
        _ = gesture.handle(.sessionChanged, context())
        #expect(drag(151, 20) == moved, "a session change does not end a triangle press")
        _ = up(151, 20)

        _ = down(101, 20)
        _ = drag(151, 20)
        #expect(gesture.handle(.escape, context()) == [.marks(marks)])
        #expect(up(151, 20) == [])
    }

    /// The time area seeks at the down, as before the mouse-edits run; the corner over the track
    /// headers does nothing.
    @Test mutating func aTimeAreaPressSeeksAtTheDown() {
        #expect(down(700, 10) == [.seek(336_000)])
        #expect(up(700, 10) == [] && !gesture.isActive, "a click makes no second seek")
        #expect(gesture.cursor(at: .ruler(x: 700, y: 10), context()) == .arrow)
        #expect(gesture.cursor(at: .ruler(x: 201, y: 10), context()) == .resizeLeftRight)
        #expect(down(-5, 10) == [] && !gesture.isActive)
    }

    /// C14: a time-area drag of 3 pt makes a range from the press frame to the pointer frame, on
    /// the header tracks of a range, else on all tracks; a drag to the left orders the points; the
    /// up seeks to the in point. Press x 250 is frame 120,000 (480 frames per point).
    @Test mutating func aRulerDragMakesARangeOnTheSelectedTracksOrAll() throws {
        let all: Set<TrackID> = ["t1", "t2", "t3"]
        let clipSet = try #require(ClipSet(["A"]))
        let rows: [(Selection, Double, Frames, Frames, Set<TrackID>)] = [
            (.range(marks), 253, 120_000, 121_440, ["t1"]),
            (.none, 253, 120_000, 121_440, all),
            (.clips(clipSet), 253, 120_000, 121_440, all),
            (.range(Marks(inPoint: 1, outPoint: 2)), 253, 120_000, 121_440, all),
            (.range(marks), 247, 118_560, 120_000, ["t1"]),
        ]
        for (start, end, low, high, tracks) in rows {
            selection = start
            let range = GestureEffect.marks(Marks(inPoint: low, outPoint: high, tracks: tracks))
            #expect(down(250, 10) == [.seek(120_000)])
            #expect(drag(end, 10) == [range], "\(start) to \(end)")
            #expect(gesture.cursor(at: .ruler(x: end, y: 10), context()) == .iBeam)
            #expect(up(end, 10) == [range, .seek(low)], "the playhead goes to the in point")
        }
        selection = .range(marks)
        _ = gesture.handle(.down(.ruler(x: 250, y: 10), shift: true, command: false), context())
        #expect(drag(253, 10) == [.marks(marks)], "Shift extends the range of the down with the same tracks")
    }

    /// C14 with View > Snap on: a ruler drag has no playhead target, so a playhead at the press
    /// frame, or 2 pt past it (a play after the seek), keeps the range. Markers still snap.
    @Test mutating func aRulerDragWithSnapOnHasNoPlayheadTarget() {
        snaps = true
        selection = .none
        let all: Set<TrackID> = ["t1", "t2", "t3"]
        for playhead in [Frames(120_000), 120_960] {
            self.playhead = playhead
            _ = down(250, 10)
            #expect(
                drag(253, 10) == [.marks(Marks(inPoint: 120_000, outPoint: 121_440, tracks: all))],
                "the playhead at \(playhead)")
            _ = up(253, 10)
        }
        playhead = 1000
        _ = down(191, 10)
        #expect(
            drag(194.5, 10) == [.marks(Marks(inPoint: 91_680, outPoint: 96_000, tracks: all))],
            "the end snaps to m1 and the end of A")
        _ = up(194.5, 10)
    }

    /// C14: under 3 pt of horizontal movement a time-area press only seeks, also with a long
    /// vertical movement.
    @Test mutating func aRulerClickUnderThreePointsOnlySeeks() {
        #expect(down(250, 10) == [.seek(120_000)])
        #expect(drag(252.9, 10) == [] && drag(250, 40) == [] && up(252.9, 40) == [])
        #expect(!gesture.isActive)
    }

    /// C14: Esc during a ruler drag gives back the selection of the down, and the up seeks nowhere.
    @Test mutating func escapeEndsARulerDragWithTheOldSelection() {
        _ = down(250, 10)
        _ = drag(260, 10)
        #expect(gesture.handle(.escape, context()) == [.marks(marks)])
        #expect(up(270, 10) == [] && !gesture.isActive)
    }

    /// Criterion 13: the ruler menu acts at the clicked frame, on the flag under the pointer (also
    /// under a triangle).
    @Test func theMenuTargetIsTheClickedFrameAndTheFlag() {
        #expect(TimelineGesture.menuTarget(at: 201, context())?.frame == 96_480)
        #expect(TimelineGesture.menuTarget(at: 201, context())?.marker == "m1")
        #expect(TimelineGesture.menuTarget(at: 700, context())?.marker == nil)
        #expect(TimelineGesture.menuTarget(at: 700, context())?.frame == 336_000)
        #expect(TimelineGesture.menuTarget(at: -5, context()) == nil)
    }
}
