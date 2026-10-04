import DirigibleCore
import Testing

@testable import DirigibleTimeline

/// The ripple trim gesture (decision 0037, criteria C6, C12, C15b, and C20) on the small fixture
/// (480 frames per point): A is x 100 to 200 pt on lane 0, B is x 300 to 400 pt. Clip D (file fb)
/// is on t2 at 120 000 ..< 144 000, and marker m is at 150 000.
struct RippleGestureTests {
    let session: Session
    var gesture = TimelineGesture()

    init() throws {
        var session = try Fixture.session()
        try session.place(Clip(id: "D", file: "fb", start: 120_000, offset: 0, length: 24_000), on: "t2")
        try session.setMarker(Marker(id: "m", name: "m", position: 150_000, kind: .marker))
        self.session = session
    }

    func context(canEdit: Bool = true, canRipple: Bool = true) -> GestureContext {
        GestureContext(
            session: session, marks: Marks(), playhead: 0, geometry: Fixture.geometry, canEdit: canEdit,
            canRipple: canRipple)
    }

    mutating func down(_ x: Double, option: Bool = true, shift: Bool = false, canRipple: Bool = true) {
        _ = gesture.handle(
            .down(.lanes(x: x, y: 10), shift: shift, command: false, option: option), context(canRipple: canRipple))
    }

    mutating func drag(_ x: Double, canEdit: Bool = true, canRipple: Bool = true) {
        _ = gesture.handle(.drag(.lanes(x: x, y: 10)), context(canEdit: canEdit, canRipple: canRipple))
    }

    mutating func up(_ x: Double, canRipple: Bool = true) -> [GestureEffect] {
        gesture.handle(.up(.lanes(x: x, y: 10)), context(canRipple: canRipple))
    }

    var drawn: Session { gesture.drawn(session) }

    /// The commits of `effects`.
    func commits(_ effects: [GestureEffect]) -> [GestureCommit] {
        effects.compactMap { if case .commit(let commit) = $0 { commit } else { nil } }
    }

    /// The result of the one commit of `effects`, or nil.
    func committed(_ effects: [GestureEffect]) -> Session? {
        guard let commit = commits(effects).first, commits(effects).count == 1 else { return nil }
        var result = session
        return commit.apply(to: &result) ? result : nil
    }

    /// C12. Control: a plain press that ripples moves B.
    @Test mutating func aPlainPressStopsAtTheNeighbor() {
        down(198, option: false)
        drag(398)
        let result = committed(up(398))
        #expect(result?.clip("A")?.clip.range == 48_000..<144_000, "the plain trim stops at B")
        #expect(result?.clip("B")?.clip.start == 144_000, "no other clip moves")
    }

    /// C12 and C6. The preview and the commit are `rippleTrim` on all tracks; the edge stops at the
    /// file, not at the neighbor. Control: an Option press that stops at the neighbor.
    @Test mutating func anOptionPressRipplesEveryTrack() throws {
        var expected = session
        try expected.rippleTrim("A", edge: .end, by: 96_000, on: ["t1", "t2", "t3"])
        down(198)
        drag(498)
        #expect(drawn == expected, "the preview stops at the file end of A, not at B")
        #expect(drawn.clip("D")?.clip.start == 216_000, "the later clip of t2 moves")
        #expect(gesture.cursor(at: .lanes(x: 600, y: 150), context()) == .rippleTrim(.end))
        let effects = up(498)
        #expect(commits(effects).count == 1, "one commit, one undo entry")
        #expect(committed(effects) == expected)
        #expect(commits(effects).first?.marks == Marks(inPoint: 48_000, outPoint: 192_000, tracks: ["t1"]))
    }

    /// C12. A drag toward the start stops at a length of 1 pt.
    @Test mutating func theRippleEdgeStopsAtOnePoint() throws {
        down(198)
        drag(-200)
        #expect(drawn.clip("A")?.clip.range == 48_000..<48_480)
        #expect(drawn.clip("B")?.clip.start == 96_480, "B follows the end of A")
    }

    /// C12 (plan gate 2 item 3): the delta comes from the pointer motion, so a start edge at frame
    /// 0 extends into the file. Control: a target frame clamped at 0.
    @Test func aStartEdgeAtFrameZeroRipplesLeft() throws {
        var session = try Fixture.session(withB: false)
        try session.place(Clip(id: "Z", file: "fb", start: 0, offset: 4_800, length: 24_000), on: "t2")
        var gesture = TimelineGesture()
        let context = GestureContext(
            session: session, marks: Marks(), playhead: 0, geometry: Fixture.geometry, canEdit: true, canRipple: true)
        _ = gesture.handle(.down(.lanes(x: 1, y: 70), shift: false, command: false, option: true), context)
        _ = gesture.handle(.drag(.lanes(x: -19, y: 70)), context)
        #expect(
            gesture.drawn(session).clip("Z")?.clip == Clip(id: "Z", file: "fb", start: 0, offset: 0, length: 28_800))
    }

    /// C12. Option with Shift keeps the 0020 range press.
    @Test mutating func optionShiftIsARangePress() {
        down(198, shift: true)
        drag(250)
        #expect(drawn == session, "no trim")
    }

    /// C12. Esc, a session change, and a take drop the ripple trim.
    @Test mutating func escapeASessionChangeOrATakeDropsIt() {
        down(198)
        drag(250)
        #expect(drawn != session, "the drag shows a preview")
        _ = gesture.handle(.escape, context())
        #expect(drawn == session && up(250) == [], "Esc")
        down(198)
        drag(250)
        _ = gesture.handle(.sessionChanged, context())
        #expect(drawn == session && up(250) == [], "a session change")
        down(198)
        drag(250)
        drag(260, canEdit: false)
        #expect(drawn == session && up(260) == [], "a take")
    }

    /// C20. Control: an Option press that commits with `canRipple` false.
    @Test mutating func anOptionPressThatCannotRippleMakesNoCommit() {
        down(198, canRipple: false)
        drag(250, canRipple: false)
        #expect(drawn == session, "no preview")
        #expect(commits(up(250, canRipple: false)).isEmpty, "no commit")
    }

    /// C15b. The drawn session holds the moved markers, and the ruler draws them. Control: the
    /// source markers.
    @Test mutating func theRulerShowsTheMovedMarkers() {
        down(198)
        drag(218)
        #expect(drawn.markers["m"]?.position == 159_600)
    }

    /// C12 cursor (row 12:03). Control: resizeLeftRight with Option held.
    @Test func optionOverATrimZoneShowsTheRippleCursor() {
        let gesture = TimelineGesture()
        let context = context()
        #expect(gesture.cursor(at: .lanes(x: 198, y: 10), context, option: true) == .rippleTrim(.end))
        #expect(gesture.cursor(at: .lanes(x: 101, y: 10), context, option: true) == .rippleTrim(.start))
        #expect(gesture.cursor(at: .lanes(x: 198, y: 10), context) == .resizeLeftRight, "no Option")
        #expect(gesture.cursor(at: .lanes(x: 150, y: 10), context, option: true) == .arrow, "the move zone")
    }
}
