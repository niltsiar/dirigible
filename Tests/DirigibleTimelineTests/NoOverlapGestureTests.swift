import DirigibleCore
import Testing

@testable import DirigibleTimeline

/// A gesture in one drag mode on the small geometry (480 frames per point, 60 pt lanes), with
/// snap off. `x(frame)` is the point whose frame is `frame`.
struct ModeGesture {
    var session: Session
    var mode: DragMode
    var gesture = TimelineGesture()
    var selection = Selection.none
    var canRipple = true

    init(_ session: Session, _ mode: DragMode) { (self.session, self.mode) = (session, mode) }

    var context: GestureContext {
        var context = GestureContext(
            session: session, selection: selection, playhead: 0, geometry: Fixture.geometry, canEdit: true,
            canRipple: canRipple, snaps: false)
        context.dragMode = mode
        return context
    }

    static func x(_ frame: Int) -> Double { (Double(frame) + 0.5) / 480 }

    mutating func down(_ frame: Int, lane: Int = 0, option: Bool = false) {
        _ = gesture.handle(
            .down(.lanes(x: Self.x(frame), y: 10 + 60 * Double(lane)), shift: false, command: false, option: option),
            context)
    }

    mutating func drag(_ frame: Int, lane: Int = 0) -> [GestureEffect] {
        gesture.handle(.drag(.lanes(x: Self.x(frame), y: 10 + 60 * Double(lane))), context)
    }

    mutating func up(_ frame: Int, lane: Int = 0) -> [GestureEffect] {
        gesture.handle(.up(.lanes(x: Self.x(frame), y: 10 + 60 * Double(lane))), context)
    }

    /// A press on the clip at `from`, one drag event for each frame of `to`, and the mouse-up at the last.
    mutating func move(from: Int, to frames: [Int], lane: Int = 0) -> [GestureEffect] {
        down(from)
        for frame in frames { _ = drag(frame, lane: lane) }
        return up(frames.last ?? from, lane: lane)
    }

    var drawn: Session { gesture.drawn(session) }

    static func commits(_ effects: [GestureEffect]) -> [GestureCommit] {
        effects.compactMap { if case .commit(let commit) = $0 { commit } else { nil } }
    }

    /// The one commit of `effects` and the session after it, or nil.
    func committed(_ effects: [GestureEffect]) -> (commit: GestureCommit, session: Session)? {
        let commits = Self.commits(effects)
        var result = session
        guard commits.count == 1, commits[0].apply(to: &result) else { return nil }
        return (commits[0], result)
    }

    /// Expects `a == b`. A failed `#expect(a == b)` of two sessions stops the test process with
    /// signal 10 as it prints them, so the failure shows the clip places and the markers.
    static func expectSame(_ a: Session, _ b: Session, sourceLocation: SourceLocation = #_sourceLocation) {
        func places(_ s: Session) -> [String] {
            s.tracks.flatMap { track in
                track.clips.map {
                    "\(track.id.rawValue):\($0.id.rawValue)@\($0.start.count)+\($0.length.count)"
                        + " x\($0.crossfades.start.count),\($0.crossfades.end.count)"
                }
            } + s.markers.values.map { "\($0.id.rawValue)@\($0.position.count)" }.sorted()
        }
        #expect(places(a) == places(b), sourceLocation: sourceLocation)
        let equal = a == b
        #expect(equal, sourceLocation: sourceLocation)
    }

    func start(_ id: ClipID, in session: Session) -> String? {
        session.clip(id).map { "\($0.track.rawValue)@\($0.clip.start.count)" }
    }
}

/// C41 window part: a No Overlap move drag stops at the neighbor clips. Fixture N: on t1, a at
/// 0 ..< 48000, b at 96000 ..< 144000, c at 192000 ..< 240000; on t2, a2 at 0 ..< 48000 and c2 at
/// 192000 ..< 240000. The press is at frame 120000 of b, so a pointer frame of f gives a wanted
/// start of f - 24000.
struct NoOverlapGestureTests {
    static func fixtureN() throws -> Session {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f", path: "f.wav", layout: .mono, length: 480_000))
        try session.addTrack("t1", name: "T1", layout: .mono)
        try session.addTrack("t2", name: "T2", layout: .mono)
        for (id, start, track) in [("a", 0, "t1"), ("b", 96_000, "t1"), ("c", 192_000, "t1"), ("a2", 0, "t2")]
            + [("c2", 192_000, "t2")]
        {
            try session.place(
                Clip(id: ClipID(id), file: "f", start: Frames(start), offset: Frames(start), length: 48_000),
                on: TrackID(id == "a2" || id == "c2" ? "t2" : track))
        }
        return session
    }

    /// Controls: no clamp commits b over c (c trimmed to start at 218000); a clamp to the nearest
    /// free start of the lane gives 240000 at a wanted 216000.
    @Test(arguments: [
        (100_000, "t1@100000"), (144_000, "t1@144000"), (144_001, "t1@144000"), (170_000, "t1@144000"),
        (192_000, "t1@144000"), (216_000, "t1@144000"), (240_000, "t1@144000"), (20_000, "t1@48000"),
        (0, "t1@48000"),
    ])
    func aMoveStopsAtItsNeighbors(wanted: Int, place: String) throws {
        var g = ModeGesture(try Self.fixtureN(), .noOverlap)
        let result = try #require(g.committed(g.move(from: 120_000, to: [wanted + 24_000])))
        let (b, c, ripple) = (
            g.start("b", in: result.session), result.session.clip("c")?.clip.range, result.commit.ripple
        )
        #expect(b == place)
        #expect(c == 192_000..<240_000, "c stays whole")
        #expect(ripple == false)
    }

    /// U56: on t2 the span is the one near the first event on that lane, kept while the drag stays
    /// there; a tie goes to the earlier span (U55).
    @Test(arguments: [
        ([170_000, 216_000], "t2@144000"), ([260_000, 200_000], "t2@240000"), ([192_000], "t2@144000"),
    ])
    func aMoveToAnotherLaneKeepsTheSpanOfItsFirstEvent(wanted: [Int], place: String) throws {
        var g = ModeGesture(try Self.fixtureN(), .noOverlap)
        let result = try #require(g.committed(g.move(from: 120_000, to: wanted.map { $0 + 24_000 }, lane: 1)))
        let b = g.start("b", in: result.session)
        #expect(b == place)
    }

    @Test func theClampShowsTheSnapMarkAndTheStopReadout() throws {
        var g = ModeGesture(try Self.fixtureN(), .noOverlap)
        g.down(120_000)
        var shown: [(Frames?, GestureReadout?)] = []
        for wanted in [170_000, 20_000, 100_000] {
            _ = g.drag(wanted + 24_000)
            shown.append((g.gesture.guide, g.gesture.readout))
        }
        let guides = shown.map(\.0)
        let readouts = shown.map(\.1)
        #expect(guides == [192_000, 48_000, nil], "the edge of b that touches c, then a; no mark when free")
        #expect(readouts == [.stopped, .stopped, nil])
    }

    /// Control: a stop effect at each clamped event gives a second effect at 192000.
    @Test func theStopAnnouncesOnceUntilTheClipIsFree() throws {
        var g = ModeGesture(try Self.fixtureN(), .noOverlap)
        g.down(120_000)
        let effects = [170_000, 192_000, 100_000, 170_000].map { g.drag($0 + 24_000) }
        #expect(effects == [[.stopAnnouncement], [], [], [.stopAnnouncement]])
    }

    /// A group drag announces each stop once, and again after it is free: the events are free,
    /// stopped, still stopped, free again, stopped.
    @Test func aGroupStopAnnouncesOnceUntilTheGroupIsFree() throws {
        var g = ModeGesture(try Self.fixtureN(), .noOverlap)
        g.selection = .clips(try #require(ClipSet(["a", "b"])))
        g.down(120_000)
        let effects = [48_000, 48_001, 48_002, 48_000, 48_001].map { g.drag(120_000 + $0) }
        #expect(effects == [[], [.stopAnnouncement], [], [], [.stopAnnouncement]])
    }

    /// A group drag keeps the last preview that passed when an event would cover a clip, with the
    /// stop readout. Control: the Overwrite nudge trims c.
    @Test func aGroupDragKeepsTheLastFreePreview() throws {
        var g = ModeGesture(try Self.fixtureN(), .noOverlap)
        g.selection = .clips(try #require(ClipSet(["a", "b"])))
        g.down(120_000)
        _ = g.drag(120_000 + 48_000)
        let free = g.gesture.readout
        _ = g.drag(120_000 + 48_001)
        let stopped = g.gesture.readout
        #expect(free == nil)
        #expect(stopped == .stopped)
        let result = try #require(g.committed(g.up(120_000 + 48_001)))
        let places = ["a", "b", "c"].map { g.start(ClipID($0), in: result.session) }
        #expect(places == ["t1@48000", "t1@144000", "t1@192000"])
    }
}
