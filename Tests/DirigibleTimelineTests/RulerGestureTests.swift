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

    init() throws {
        var session = try Fixture.session()
        try session.setMarker(Marker(id: "m1", name: "Intro", position: 96_000, kind: .marker))
        self.session = session
    }

    func context(_ session: Session? = nil, canEdit: Bool = true) -> GestureContext {
        GestureContext(
            session: session ?? self.session, marks: marks, playhead: 1000, geometry: Fixture.geometry,
            canEdit: canEdit)
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

    var drawn: Session { gesture.drawn(session: session, marks: marks).session }

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
        #expect(result?.commit.marker == "m1" && result?.commit.marks == nil)
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
        #expect(down(700, 10) == [.seek(336_000)] && !gesture.isActive)
        #expect(gesture.cursor(at: .ruler(x: 700, y: 10), context()) == .arrow)
        #expect(gesture.cursor(at: .ruler(x: 201, y: 10), context()) == .resizeLeftRight)
        #expect(down(-5, 10) == [] && !gesture.isActive)
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
