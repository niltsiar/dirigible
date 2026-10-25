import DirigibleCore
import Testing

@testable import DirigibleTimeline

/// The fixture of the clip selection tests (decision 0038): 480 frames per point, 60 pt lanes, and
/// the mono tracks t1 to t4. A (file fa) on t1 and B (file fb) on t2 at 48,000 ..< 96,000 (x 100
/// to 200 pt; the move zone of a lane is its upper 40 pt). C on t1 at 144,000 ..< 192,000 (x 300
/// to 400 pt) and D on t3 at 240,000 ..< 288,000 (x 500 to 600 pt).
struct GroupGesture {
    var session: Session
    var selection = Selection.none
    var canEdit = true
    var gesture = TimelineGesture()

    init() throws {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "fa", path: "fa.wav", layout: .mono, length: 480_000))
        try session.addFile(AudioFile(id: "fb", path: "fb.wav", layout: .mono, length: 480_000))
        for n in 1...4 { try session.addTrack(TrackID("t\(n)"), name: "T\(n)", layout: .mono) }
        try session.place(Clip(id: "A", file: "fa", start: 48_000, offset: 0, length: 48_000), on: "t1")
        try session.place(Clip(id: "B", file: "fb", start: 48_000, offset: 0, length: 48_000), on: "t2")
        try session.place(Clip(id: "C", file: "fa", start: 144_000, offset: 48_000, length: 48_000), on: "t1")
        try session.place(Clip(id: "D", file: "fb", start: 240_000, offset: 48_000, length: 48_000), on: "t3")
        self.session = session
    }

    static func clips(_ ids: Set<ClipID>) -> Selection { ClipSet(ids).map { .clips($0) } ?? .none }

    var context: GestureContext {
        GestureContext(
            session: session, selection: selection, playhead: 0, geometry: Fixture.geometry, canEdit: canEdit,
            canRipple: true)
    }

    mutating func down(_ x: Double, _ y: Double, command: Bool = false) -> [GestureEffect] {
        gesture.handle(.down(.lanes(x: x, y: y), shift: false, command: command), context)
    }

    mutating func drag(_ x: Double, _ y: Double) -> [GestureEffect] {
        gesture.handle(.drag(.lanes(x: x, y: y)), context)
    }

    mutating func up(_ x: Double, _ y: Double) -> [GestureEffect] { gesture.handle(.up(.lanes(x: x, y: y)), context) }

    /// A click: a down and an up at one point.
    mutating func click(_ x: Double, _ y: Double, command: Bool = false) -> [GestureEffect] {
        _ = down(x, y, command: command)
        return up(x, y)
    }

    /// A drag from a down to an up, through one drag event.
    mutating func move(from: (Double, Double), to: (Double, Double)) -> [GestureEffect] {
        _ = down(from.0, from.1)
        _ = drag(to.0, to.1)
        return up(to.0, to.1)
    }

    /// The session after the one commit of `effects`, and its selection; nil when there is none.
    func committed(_ effects: [GestureEffect]) -> (session: Session, selection: Selection?)? {
        guard effects.count == 1, case .commit(let commit) = effects[0] else { return nil }
        var result = session
        return commit.apply(to: &result) ? (result, commit.selection) : nil
    }

    /// The track and the start of each clip, by ID.
    static func places(_ session: Session?) -> [ClipID: String] {
        var places: [ClipID: String] = [:]
        for track in session?.tracks ?? [] {
            for clip in track.clips { places[clip.id] = "\(track.id)@\(clip.start)" }
        }
        return places
    }
}

/// Multi-clip-selection C1 and C5 to C7: a drag of a clip in a selection of 2 or more clips moves
/// them all with one `nudge`.
struct GroupMoveGestureTests {
    var g: GroupGesture

    init() throws { g = try GroupGesture() }

    /// C1, the A5 repro. Control: the single move of today moves A alone onto B.
    @Test mutating func aDragOfAClipInARangeMovesEveryClipThatTheRangeHoldsWhole() throws {
        g.selection = .range(Marks(inPoint: 48_000, outPoint: 96_000, tracks: ["t1", "t2"]))
        let result = try #require(g.committed(g.move(from: (150, 10), to: (200, 70))))
        #expect(
            GroupGesture.places(result.session) == [
                "A": "t2@72000", "B": "t3@72000", "C": "t1@144000", "D": "t3@240000",
            ])
        #expect(result.selection == GroupGesture.clips(["A", "B"]), "a shifted range is not safe")
    }

    /// C5: each clip keeps its lane and time offsets.
    @Test mutating func theSetKeepsItsLaneAndTimeOffsets() throws {
        g.selection = GroupGesture.clips(["A", "D"])
        _ = g.down(150, 10)
        _ = g.drag(175, 70)
        #expect(GroupGesture.places(g.gesture.drawn(g.session))["D"] == "t4@252000", "the preview")
        let result = try #require(g.committed(g.up(175, 70)))
        #expect(
            GroupGesture.places(result.session).filter { ["A", "D"].contains($0.key) } == [
                "A": "t2@60000", "D": "t4@252000",
            ])
    }

    /// C6: (a) the lane delta clamps so that each clip has a track; (b) a target of the other
    /// layout keeps every clip on its lane, and the group still moves in time; (c) the first clip
    /// stops at frame 0.
    @Test mutating func theLaneDeltaClampsAndALayoutMismatchKeepsTheLanes() throws {
        g.selection = GroupGesture.clips(["A", "D"])
        let clamped = try #require(g.committed(g.move(from: (150, 10), to: (150, 190))))
        #expect(GroupGesture.places(clamped.session)["A"] == "t2@48000", "three lanes down clamps to one")
        #expect(GroupGesture.places(clamped.session)["D"] == "t4@240000")

        try g.session.addTrack("st", name: "Stereo", layout: .stereo)
        let kept = try #require(g.committed(g.move(from: (150, 10), to: (200, 130))))
        #expect(GroupGesture.places(kept.session)["A"] == "t1@72000", "D would go to the stereo track")
        #expect(GroupGesture.places(kept.session)["D"] == "t3@264000")

        let left = try #require(g.committed(g.move(from: (150, 10), to: (0, 10))))
        #expect(
            GroupGesture.places(left.session)["A"] == "t1@0" && GroupGesture.places(left.session)["D"] == "t3@192000")
    }

    /// C7a: a moved clip overwrites the unselected clip under it, as a single drop does. The part of
    /// C that stays is its first part, so it keeps its ID (`ClipLane.clear`).
    @Test mutating func aMovedClipOverwritesAnUnselectedClip() throws {
        g.selection = GroupGesture.clips(["A", "B"])
        let result = try #require(g.committed(g.move(from: (150, 10), to: (270, 10))))
        #expect(result.session.tracks[0].clips.map(\.id) == ["A", "C"])
        #expect(GroupGesture.places(result.session)["C"] == "t1@153600")
        #expect(GroupGesture.places(result.session)["B"] == "t2@105600")
    }

    /// The state table of design.md: Esc and a session change during a group drag drop it, with no
    /// commit and no selection change; the group drag after them starts again from the set.
    @Test mutating func escapeAndASessionChangeDropTheGroupDrag() {
        g.selection = GroupGesture.clips(["A", "B"])
        _ = g.down(150, 10)
        _ = g.drag(200, 10)
        #expect(g.gesture.drawn(g.session) != g.session, "the drag shows a preview")
        #expect(g.gesture.handle(.escape, g.context) == [])
        #expect(g.up(200, 10) == [] && g.gesture.drawn(g.session) == g.session)
        _ = g.down(150, 10)
        _ = g.drag(200, 10)
        #expect(g.gesture.handle(.sessionChanged, g.context) == [])
        #expect(g.up(200, 10) == [])
    }

    /// A range that holds one clip only drags that clip alone (the single move).
    @Test mutating func aRangeOfOneClipMovesThatClipAlone() throws {
        g.selection = .range(Marks(inPoint: 48_000, outPoint: 96_000, tracks: ["t1"]))
        let result = try #require(g.committed(g.move(from: (150, 10), to: (200, 10))))
        #expect(result.selection == .clips(ClipSet("A")))
    }
}
