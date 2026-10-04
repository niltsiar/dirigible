import DirigibleCore
import Testing

@testable import DirigibleTimeline

/// Mouse-edits criteria 2 to 5, 8, and 9: the gesture on the small fixture (480 frames per point,
/// 60 pt lanes; A is x 100 to 200 pt on lane 0, its move zone is y 0 to 40 pt).
struct GestureTests {
    let session: Session
    var gesture = TimelineGesture()

    init() throws { session = try Fixture.session() }

    func context(
        _ session: Session? = nil, marks: Marks = Marks(), playhead: Frames = 1000, canEdit: Bool = true
    ) -> GestureContext {
        GestureContext(
            session: session ?? self.session, marks: marks, playhead: playhead, geometry: Fixture.geometry,
            canEdit: canEdit, canRipple: true)
    }

    mutating func down(_ x: Double, _ y: Double, shift: Bool = false, command: Bool = false) -> [GestureEffect] {
        gesture.handle(.down(.lanes(x: x, y: y), shift: shift, command: command), context())
    }

    mutating func drag(_ x: Double, _ y: Double, canEdit: Bool = true) -> [GestureEffect] {
        gesture.handle(.drag(.lanes(x: x, y: y)), context(canEdit: canEdit))
    }

    mutating func up(_ x: Double, _ y: Double, canEdit: Bool = true) -> [GestureEffect] {
        gesture.handle(.up(.lanes(x: x, y: y)), context(canEdit: canEdit))
    }

    var drawn: Session { gesture.drawn(session) }

    /// The session after the one commit of `effects`, or nil when there is none.
    func committed(_ effects: [GestureEffect]) -> Session? {
        guard effects.count == 1, case .commit(let commit) = effects[0] else { return nil }
        var result = session
        return commit.apply(to: &result) ? result : nil
    }

    /// The track and the frames of a clip.
    struct Spot: Equatable {
        let track: TrackID
        let range: Range<Frames>
        init(_ track: TrackID, _ range: Range<Frames>) { (self.track, self.range) = (track, range) }
    }

    func place(_ id: ClipID, in session: Session?) -> Spot? {
        session?.clip(id).map { Spot($0.track, $0.clip.range) }
    }

    @Test mutating func aClickOnAClipSelectsItsRangeOnItsTrackWithNoSeek() {
        let range = [GestureEffect.marks(Marks(inPoint: 48_000, outPoint: 96_000, tracks: ["t1"]))]
        _ = down(150, 10)
        #expect(drag(151, 11) == [])
        #expect(up(152, 11) == range, "the move zone, 2.2 pt of movement")
        _ = down(102, 10)
        #expect(up(102, 10) == range, "the trim zone")
        #expect(!gesture.isActive && drawn == session)
    }

    /// Code gate 1 item 1: the jitter of a click (0.5 pt right, 3 pt down) moves and trims nothing.
    /// The time delta applies only from 3 pt of horizontal movement, so a clip keeps its sync.
    @Test mutating func aClickWithJitterIsAClickWithNoEdit() {
        let range = [GestureEffect.marks(Marks(inPoint: 48_000, outPoint: 96_000, tracks: ["t1"]))]
        _ = down(150, 10)
        #expect(up(150.5, 13) == range, "the move zone")
        _ = down(101, 10)
        #expect(up(101.5, 13) == range, "the trim zone")
        _ = down(150, 10)
        _ = drag(150.5, 34)
        #expect(place("A", in: drawn) == Spot("t1", 48_000..<96_000), "a vertical drag keeps the time")
        _ = drag(153, 34)
        #expect(place("A", in: drawn) == Spot("t1", 49_440..<97_440), "3 pt of horizontal movement")
    }

    @Test mutating func aClickInTheRangeZoneSeeksAndEmptiesTheMarks() {
        _ = down(150, 50)
        #expect(up(150, 50) == [.marks(Marks()), .seek(72_000)], "the lower third of A")
        _ = down(250, 10)
        #expect(up(250, 10) == [.marks(Marks()), .seek(120_000)], "the gap after A")
        _ = down(150, 200)
        #expect(up(150, 200) == [], "under the last lane")
    }

    @Test mutating func aMoveDragPreviewsAndCommitsOnceAtUp() {
        _ = down(150, 10)
        #expect(drag(200, 10) == [])
        #expect(place("A", in: drawn) == Spot("t1", 72_000..<120_000))
        #expect(drag(250, 10) == [])
        #expect(place("A", in: drawn) == Spot("t1", 96_000..<144_000), "the preview")

        let effects = up(250, 10)

        let result = committed(effects)
        #expect(place("A", in: result) == Spot("t1", 96_000..<144_000))
        #expect(result?.clip("A")?.clip.offset == 0 && result?.clip("B")?.clip == Fixture.b)
        guard case .commit(let commit) = effects.first else { return }
        #expect(commit.marks == Marks(inPoint: 96_000, outPoint: 144_000, tracks: ["t1"]))
        #expect(!gesture.isActive && drawn == session)
    }

    /// Criterion 4: A to 150,000 ..< 198,000 cuts B as `place` does (decision 0003).
    @Test mutating func aMoveOntoAClipOverwritesIt() {
        _ = down(150, 10)
        _ = drag(362.5, 10)
        let result = committed(up(362.5, 10))

        #expect(place("A", in: result) == Spot("t1", 150_000..<198_000))
        #expect(result?.track("t1")?.clips.map(\.id) == ["B", "A"])
        #expect(place("B", in: result) == Spot("t1", 144_000..<150_000))
    }

    /// Criterion 5: one lane down is t2 (mono); two lanes down is t3 (stereo), so A stays on t1.
    @Test mutating func aMoveGoesToALaneOfTheSameLayoutOnly() {
        _ = down(150, 10)
        _ = drag(250, 70)
        #expect(place("A", in: committed(up(250, 70))) == Spot("t2", 96_000..<144_000))

        _ = down(150, 10)
        _ = drag(250, 130)
        #expect(place("A", in: committed(up(250, 130))) == Spot("t1", 96_000..<144_000))
    }

    @Test mutating func aMoveStopsAtFrameZero() {
        _ = down(150, 10)
        _ = drag(-50, 10)
        #expect(place("A", in: committed(up(-50, 10))) == Spot("t1", 0..<48_000))
    }

    /// Plan gate 1 item 1: 0.4 lane of vertical movement keeps the lane; 0.6 lane changes it.
    @Test mutating func aLaneChangeNeedsHalfALane() {
        _ = down(150, 10)
        _ = drag(250, 34)
        #expect(place("A", in: drawn) == Spot("t1", 96_000..<144_000))
        _ = drag(250, 46)
        #expect(place("A", in: drawn) == Spot("t2", 96_000..<144_000))
    }

    @Test mutating func escapeDropsThePreview() {
        _ = down(150, 10)
        _ = drag(250, 10)

        #expect(gesture.handle(.escape, context()) == [])

        #expect(drawn == session && gesture.isActive, "dropped until the up")
        #expect(drag(300, 10) == [] && drawn == session)
        #expect(up(300, 10) == [] && !gesture.isActive)
    }

    /// Criterion 8, pulled forward from slice 4: Esc during a range drag gives back the Marks of the
    /// mouse-down.
    @Test mutating func escapeDuringARangeDragRestoresTheMarksAtDown() {
        let marks = Marks(inPoint: 0, outPoint: 1000, tracks: ["t2"])
        _ = gesture.handle(.down(.lanes(x: 250, y: 10), shift: false, command: false), context(marks: marks))
        #expect(drag(260, 70) == [.marks(Marks(inPoint: 120_000, outPoint: 124_800, tracks: ["t1", "t2"]))])

        #expect(gesture.handle(.escape, context()) == [.marks(marks)])

        #expect(up(270, 70) == [])
    }

    @Test mutating func aSessionChangeMidDragDropsThePreviewAndTheCommit() throws {
        _ = down(150, 10)
        _ = drag(250, 10)
        var changed = session
        try changed.renameTrack("t2", to: "Guest")

        #expect(gesture.handle(.sessionChanged, context(changed)) == [])

        #expect(drawn == session)
        #expect(up(250, 10) == [])
        _ = down(198, 10)
        _ = drag(150, 10)
        _ = gesture.handle(.sessionChanged, context(changed))
        #expect(drawn == session && up(150, 10) == [], "a trim")
    }

    @Test mutating func aCommitOnAChangedSessionChangesNothing() throws {
        _ = down(150, 10)
        _ = drag(250, 10)
        let effects = up(250, 10)
        guard case .commit(let commit) = effects.first else {
            Issue.record("no commit: \(effects)")
            return
        }
        var changed = session
        try changed.renameTrack("t2", to: "Guest")
        let before = changed

        #expect(!commit.apply(to: &changed))

        #expect(changed == before)
    }

    @Test mutating func aTakeStartMidDragDropsTheCommit() {
        _ = down(150, 10)
        _ = drag(200, 10)

        #expect(drag(250, 10, canEdit: false) == [])

        #expect(drawn == session)
        #expect(up(250, 10) == [])
    }

    @Test mutating func noPreviewWhenATakeRunsAtTheDown() {
        _ = down(150, 10)
        _ = drag(250, 10, canEdit: false)

        #expect(drawn == session)
        #expect(up(250, 10, canEdit: false) == [.marks(Marks(inPoint: 48_000, outPoint: 96_000, tracks: ["t1"]))])
    }

    /// A lost mouse-up (an alert opened during the drag): the next mouse-down starts over.
    @Test mutating func aDownDuringAGestureStartsOver() {
        _ = down(150, 10)
        _ = drag(250, 10)

        _ = down(250, 50)

        #expect(drawn == session)
        #expect(up(250, 50) == [.marks(Marks()), .seek(120_000)])
    }

    /// The session after one drag of `edge` from `from` to `to` pt at y 10, on `session`.
    func trimmed(_ session: Session, from: Double, to: Double) -> Session? {
        var gesture = TimelineGesture()
        let context = context(session)
        _ = gesture.handle(.down(.lanes(x: from, y: 10), shift: false, command: false), context)
        _ = gesture.handle(.drag(.lanes(x: to, y: 10)), context)
        let effects = gesture.handle(.up(.lanes(x: to, y: 10)), context)
        guard effects.count == 1, case .commit(let commit) = effects[0] else { return nil }
        var result = session
        return commit.apply(to: &result) ? result : nil
    }

    /// Criterion 6: each edge drag goes in one event, so a trim with no limits throws in Core and
    /// commits nothing.
    @Test func anEdgeDragStopsAtTheNeighborTheFileAndTheMinimum() throws {
        #expect(place("A", in: trimmed(session, from: 198, to: 398)) == Spot("t1", 48_000..<144_000), "B")
        let withoutB = try Fixture.session(withB: false)
        #expect(place("A", in: trimmed(withoutB, from: 198, to: 498)) == Spot("t1", 48_000..<192_000), "fa")
        #expect(place("B", in: trimmed(session, from: 302, to: 52)) == Spot("t1", 96_000..<192_000), "A")
        #expect(trimmed(session, from: 302, to: 52)?.clip("B")?.clip.offset == 0)
        #expect(place("A", in: trimmed(session, from: 101, to: 401)) == Spot("t1", 95_520..<96_000), "1 pt")
        #expect(place("A", in: trimmed(session, from: 198, to: -102)) == Spot("t1", 48_000..<48_480), "1 pt")
    }

    @Test mutating func aLeftEdgeDragMovesTheStartAndTheOffset() {
        _ = down(101, 10)
        #expect(drag(121, 10) == [])
        #expect(place("A", in: drawn) == Spot("t1", 57_600..<96_000), "the preview")
        #expect(gesture.cursor(at: .lanes(x: 500, y: 150), context()) == .resizeLeftRight)

        let effects = up(121, 10)

        let result = committed(effects)
        #expect(place("A", in: result) == Spot("t1", 57_600..<96_000) && result?.clip("A")?.clip.offset == 9_600)
        guard case .commit(let commit) = effects.first else { return }
        #expect(commit.marks == Marks(inPoint: 57_600, outPoint: 96_000, tracks: ["t1"]))
        #expect(!gesture.isActive && drawn == session)
        _ = down(101, 10)
        _ = drag(121, 10)
        _ = drag(101, 10)
        #expect(
            up(101, 10) == [.marks(Marks(inPoint: 48_000, outPoint: 96_000, tracks: ["t1"]))],
            "the edge went back: a click, no commit")
    }

    @Test mutating func escapeDropsATrim() {
        _ = down(101, 10)
        _ = drag(121, 10)

        #expect(gesture.handle(.escape, context()) == [])

        #expect(drawn == session && up(121, 10) == [])
    }

    @Test mutating func aTakeStartMidTrimDropsTheCommit() {
        _ = down(198, 10)
        _ = drag(150, 10)
        #expect(drag(140, 10, canEdit: false) == [] && drawn == session)
        #expect(up(140, 10) == [])
        _ = down(198, 10)
        _ = drag(150, 10, canEdit: false)
        #expect(drawn == session, "no preview when a take runs at the down")
        #expect(up(150, 10, canEdit: false) == [.marks(Marks(inPoint: 48_000, outPoint: 96_000, tracks: ["t1"]))])
    }

    /// Criterion 10: with Shift, a drag from the move zone of A is a range drag. The Marks are the
    /// hull of the Marks at the down and the drag range, on the union of the tracks.
    @Test mutating func aShiftDragExtendsTheMarks() {
        let marks = Marks(inPoint: 0, outPoint: 1000, tracks: ["t2"])
        _ = gesture.handle(.down(.lanes(x: 150, y: 10), shift: true, command: false), context(marks: marks))

        let effects = gesture.handle(.drag(.lanes(x: 250, y: 10)), context(marks: marks))

        #expect(effects == [.marks(Marks(inPoint: 0, outPoint: 120_000, tracks: ["t1", "t2"]))])
        #expect(drawn == session && gesture.cursor(at: .lanes(x: 150, y: 10), context()) == .iBeam)
        #expect(up(250, 10) == [.marks(Marks(inPoint: 0, outPoint: 120_000, tracks: ["t1", "t2"]))])
    }

    /// Criterion 10: a Shift press on a clip is a range press; its click keeps the Shift-click
    /// rule (from the playhead, the lane joins).
    @Test mutating func aShiftPressOnAClipIsARangePress() {
        let marks = Marks(inPoint: 0, outPoint: 1000, tracks: ["t2"])
        _ = gesture.handle(.down(.lanes(x: 150, y: 10), shift: true, command: false), context(marks: marks))

        let effects = gesture.handle(.up(.lanes(x: 150, y: 10)), context(marks: marks))

        #expect(effects == [.marks(Marks(inPoint: 1000, outPoint: 72_000, tracks: ["t1", "t2"]))])
        _ = down(198, 10, shift: true)
        _ = drag(250, 10)
        #expect(drawn == session, "no trim")
    }
}
