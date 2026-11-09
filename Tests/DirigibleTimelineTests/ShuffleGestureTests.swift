import DirigibleCore
import Testing

@testable import DirigibleTimeline

/// C44, C57, and C58: the drags in Shuffle mode. Fixture S: on t1, a at 0 ..< 48000, b at 96000 ..<
/// 144000, c at 192000 ..< 240000, d at 288000 ..< 336000, each at its own offset of f; on t2, e at
/// 0 ..< 480000 (file g); markers m1 at 200000, m2 at 120000, m3 at 400000. A move press is at
/// frame 120000 of b, so a pointer frame of f gives a wanted start of f - 24000.
struct ShuffleGestureTests {
    static func fixtureS(follow: Bool = false) throws -> Session {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f", path: "f.wav", layout: .mono, length: 480_000))
        try session.addFile(AudioFile(id: "g", path: "g.wav", layout: .mono, length: 480_000))
        try session.addTrack("t1", name: "T1", layout: .mono)
        try session.addTrack("t2", name: "T2", layout: .mono)
        for (id, start) in [("a", 0), ("b", 96_000), ("c", 192_000), ("d", 288_000)] {
            try session.place(
                Clip(id: ClipID(id), file: "f", start: Frames(start), offset: Frames(start), length: 48_000), on: "t1")
        }
        try session.place(Clip(id: "e", file: "g", start: 0, offset: 0, length: 480_000), on: "t2")
        for (id, position) in [("m1", 200_000), ("m2", 120_000), ("m3", 400_000)] {
            try session.setMarker(Marker(id: MarkerID(id), name: id, position: Frames(position), kind: .marker))
        }
        if follow { try session.setFollowTrack(true, tracks: ["t1"]) }
        return session
    }

    static let drops = [(160_000, 144_000), (170_000, 192_000), (168_000, 144_000), (240_000, 240_000)]

    /// Control: the wanted start passed to `shuffle` splits c at 160000.
    @Test(arguments: drops)
    func aDropInsideAClipGoesToItsNearerEdge(wanted: Int, drop: Int) throws {
        let session = try Self.fixtureS()
        var expected = session
        try expected.shuffle("b", to: "t1", start: Frames(drop))
        var g = ModeGesture(session, .shuffle)
        g.down(120_000)
        _ = g.drag(wanted + 24_000)
        ModeGesture.expectSame(g.drawn, expected)
        let count = g.drawn.tracks[0].clips.count
        #expect(count == 4, "no clip splits")
        let result = try #require(g.committed(g.up(wanted + 24_000)))
        ModeGesture.expectSame(result.session, expected)
    }

    /// C51: the close names its source lane, so a follow t1 edits too. Control: a close with no
    /// `naming:` throws `.noRippleTrack`, and the drag gives no drop.
    @Test(arguments: drops)
    func aShuffleDragFromAFollowTrackDropsAtAnEdge(wanted: Int, drop: Int) throws {
        let session = try Self.fixtureS(follow: true)
        var expected = session
        try expected.shuffle("b", to: "t1", start: Frames(drop))
        var g = ModeGesture(session, .shuffle)
        let result = try #require(g.committed(g.move(from: 120_000, to: [wanted + 24_000])))
        ModeGesture.expectSame(result.session, expected)
    }

    /// Each event previews `shuffle` of the press session to its target, also after a lane change
    /// and back at the start of b, where the preview is the press session. Control: an event back
    /// at the start of b that drops on the closed tracks (m2 goes to 144000).
    @Test func eachEventOfAShuffleDragPreviewsTheShuffleOfThePressSession() throws {
        let session = try Self.fixtureS()
        let events = [
            (170_000, 0, "t1", 192_000), (264_000, 0, "t1", 240_000), (170_000, 1, "t2", 0), (96_000, 0, "t1", 96_000),
            (20_000, 0, "t1", 0),
        ]
        var g = ModeGesture(session, .shuffle)
        g.down(120_000)
        var expected = session
        for (wanted, lane, track, drop) in events {
            expected = session
            try expected.shuffle("b", to: TrackID(track), start: Frames(drop))
            _ = g.drag(wanted + 24_000, lane: lane)
            ModeGesture.expectSame(g.drawn, expected)
        }
        let result = try #require(g.committed(g.up(20_000 + 24_000)))
        ModeGesture.expectSame(result.session, expected)
    }

    /// Control: a commit with `ripple: false`.
    @Test func aShuffleCommitIsARipple() throws {
        var g = ModeGesture(try Self.fixtureS(), .shuffle)
        let result = try #require(g.committed(g.move(from: 120_000, to: [264_000])))
        let (ripple, selection) = (result.commit.ripple, result.commit.selection)
        let places = ["b", "c"].map { g.start(ClipID($0), in: result.session) }
        #expect(ripple == true)
        #expect(selection == .clips(ClipSet("b")))
        #expect(places == ["t1@240000", "t1@144000"])
    }

    /// 0037: a Shuffle press under a pending or split take beeps once and makes no edit.
    @Test func aShufflePressUnderASplitTakeBeeps() throws {
        var g = ModeGesture(try Self.fixtureS(), .shuffle)
        g.canRipple = false
        g.down(120_000)
        let effects = [g.drag(170_000), g.drag(190_000)]
        #expect(effects == [[.beep], []])
        ModeGesture.expectSame(g.drawn, g.session)
        let commits = ModeGesture.commits(g.up(190_000)).count
        #expect(commits == 0)
    }

    /// A clip may end past `Frames.limit`: its close throws `.frameOutOfRange`. The press ends with
    /// one beep, no preview, and no edit. Control: a gesture that keeps the press retries the close
    /// at each event with no beep.
    @Test func aShuffleDragWhoseCloseFailsBeepsOnce() throws {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f", path: "f.wav", layout: .mono, length: 480_000))
        try session.addTrack("t1", name: "T1", layout: .mono)
        let start = Int(Frames.limit.count) - 24_000
        try session.place(Clip(id: "z", file: "f", start: Frames(start), offset: 0, length: 48_000), on: "t1")
        var copy = session
        #expect(throws: SessionError.frameOutOfRange) {
            try copy.rippleDelete(Frames(start)..<Frames(start + 48_000), on: ["t1"], naming: ["t1"])
        }
        var g = ModeGesture(session, .shuffle)
        g.down(start + 24_000)
        let effects = [g.drag(start + 12_000), g.drag(start)]
        #expect(effects == [[.beep], []])
        ModeGesture.expectSame(g.drawn, g.session)
        let commits = ModeGesture.commits(g.up(start)).count
        #expect(commits == 0)
    }

    /// U14: a group move is no ripple, so it overwrites. Control: `.shuffle` reaches `nudge` with
    /// no `overlap` map.
    @Test func aGroupMoveInShuffleOverwrites() throws {
        let session = try Self.fixtureS()
        var expected = session
        try expected.nudge(["b", "c"], by: 72_000)
        var g = ModeGesture(session, .shuffle)
        g.selection = .clips(try #require(ClipSet(["b", "c"])))
        let result = try #require(g.committed(g.move(from: 120_000, to: [192_000])))
        ModeGesture.expectSame(result.session, expected)
        let (d, ripple) = (result.session.clip("d")?.clip.start, result.commit.ripple)
        #expect(d == 312_000, "c trims d")
        #expect(ripple == false)
    }

    /// The end of b by -24000 (50 pt) in a ripple trim of t1 alone. Control: the all-tracks scope
    /// changes t2.
    @Test func aShuffleEdgeDragRipplesItsOwnTrack() throws {
        let session = try Self.fixtureS()
        var g = ModeGesture(session, .shuffle)
        g.down(143_000)
        _ = g.drag(119_000)
        let result = try #require(g.committed(g.up(119_000)))
        let s = result.session
        let ripple = result.commit.ripple
        let b = s.clip("b")?.clip.range
        let starts = [s.clip("c")?.clip.start, s.clip("d")?.clip.start]
        let t2 = s.tracks[1].clips.map(\.range)
        let markers = ["m1", "m2", "m3"].map { s.markers[MarkerID($0)]?.position }
        #expect(ripple == true)
        #expect(b == 96_000..<120_000)
        #expect(starts == [168_000, 264_000])
        #expect(t2 == [0..<480_000], "t2 stays")
        #expect(markers == [176_000, 120_000, 376_000])
    }

    /// 0037: Option ripples all tracks in Shuffle mode too.
    @Test func anOptionEdgeDragInShuffleRipplesAllTracks() throws {
        let session = try Self.fixtureS()
        var expected = session
        try expected.rippleTrim("b", edge: .end, by: -24_000, on: ["t1", "t2"], naming: [])
        var g = ModeGesture(session, .shuffle)
        g.down(143_000, option: true)
        _ = g.drag(119_000)
        let result = try #require(g.committed(g.up(119_000)))
        ModeGesture.expectSame(result.session, expected)
        let t2 = result.session.tracks[1].clips.count
        #expect(t2 > 1, "t2 ripples")
    }

    /// 0020: a plain edge drag in No Overlap mode is the trim of today, which stops at c.
    @Test func aPlainEdgeDragInNoOverlapTrims() throws {
        var g = ModeGesture(try Self.fixtureS(), .noOverlap)
        g.down(143_000)
        _ = g.drag(263_000)
        let result = try #require(g.committed(g.up(263_000)))
        let (ripple, b) = (result.commit.ripple, result.session.clip("b")?.clip.range)
        let c = result.session.clip("c")?.clip.start
        #expect(ripple == false)
        #expect(b == 96_000..<192_000)
        #expect(c == 192_000)
    }

    /// Control: a beep that reads `press.option` gives a ripple preview of t1 under a split take.
    @Test func aShuffleEdgePressUnderASplitTakeBeeps() throws {
        var g = ModeGesture(try Self.fixtureS(), .shuffle)
        g.canRipple = false
        g.down(143_000)
        let effects = g.drag(119_000)
        #expect(effects == [.beep])
        ModeGesture.expectSame(g.drawn, g.session)
        let commits = ModeGesture.commits(g.up(119_000)).count
        #expect(commits == 0)
    }

    /// C58: the hover over a trim zone with no key down. Control: the hover reads `option` only.
    @Test func aShuffleTrimZoneShowsTheRippleCursor() throws {
        let g = ModeGesture(try Self.fixtureS(), .shuffle)
        let edge = Place.lanes(x: ModeGesture.x(143_000), y: 10)
        let overwrite = ModeGesture(g.session, .overwrite)
        let cursors = [g.gesture.cursor(at: edge, g.context), overwrite.gesture.cursor(at: edge, overwrite.context)]
        #expect(cursors[0] == .rippleTrim(.end))
        #expect(cursors[1] != .rippleTrim(.end))
    }
}
