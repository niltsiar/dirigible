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
            canEdit: canEdit)
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

    var drawn: Session { gesture.drawn(session: session, marks: Marks()).session }

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
}
