import Foundation
import Testing

@testable import DirigibleCore

/// Ripple delete and ripple insert (decision 0037, criteria C1, C3, C4, C5, and C18). The fixture is
/// `editFixture()`: tracks "a" and "b" (mono) and "s" (stereo), files "f" (mono) and "g" (stereo),
/// 480 000 frames each. Each test places its own clips.
struct RippleTests {
    var session: Session

    init() throws {
        session = try editFixture()
    }

    func lane(_ track: TrackID) -> [Clip] {
        session.track(track).map { Array($0.clips) } ?? []
    }

    func position(_ id: MarkerID) -> Frames? { session.markers[id]?.position }

    mutating func marker(_ id: MarkerID, at position: Frames) throws {
        try session.setMarker(Marker(id: id, name: id.rawValue, position: position, kind: .marker))
    }

    /// All crossfades of the lanes, by clip ID; a clip with none is left out.
    var allCrossfades: [ClipID: Crossfades] {
        Dictionary(
            uniqueKeysWithValues: session.tracks.flatMap(\.clips).filter { $0.crossfades != .zero }.map {
                ($0.id, $0.crossfades)
            })
    }

    /// C1. Controls: a ripple with no move leaves "A@96000" at 96 000 (a gap); a ripple of every
    /// track moves "G" on "s".
    @Test mutating func rippleDeleteClosesTheGapOnEachScopeTrack() throws {
        try session.place(Clip(id: "A", file: "f", start: 0, offset: 0, length: 120_000), on: "a")
        try session.place(Clip(id: "B", file: "f", start: 130_000, offset: 130_000, length: 20_000), on: "a")
        try session.place(Clip(id: "C", file: "f", start: 50_000, offset: 0, length: 100_000), on: "b")
        try session.place(Clip(id: "G", file: "g", start: 60_000, offset: 0, length: 60_000), on: "s")
        let music = lane("s")
        try session.rippleDelete(48_000..<96_000, on: ["a", "b"])
        #expect(
            lane("a") == [
                Clip(id: "A", file: "f", start: 0, offset: 0, length: 48_000),
                Clip(id: "A@96000", file: "f", start: 48_000, offset: 96_000, length: 24_000),
                Clip(id: "B", file: "f", start: 82_000, offset: 130_000, length: 20_000),
            ], "track a closes the gap")
        #expect(
            lane("b") == [Clip(id: "C", file: "f", start: 48_000, offset: 46_000, length: 54_000)],
            "track b closes the gap")
        #expect(lane("s") == music, "track s is out of scope and does not change")
    }

    /// C3 (Session). Host, guest, and music; a ripple delete of 48 000..<96 000 on host and guest.
    /// Controls: markers that move only with all tracks stay at 60 000 and 144 000; a marker inside
    /// R that goes is not at 48 000.
    @Test mutating func markersFollowTheRippleWithTheMusicOutOfScope() throws {
        try session.place(Clip(id: "H", file: "f", start: 0, offset: 0, length: 200_000), on: "a")
        try session.place(Clip(id: "U", file: "f", start: 0, offset: 0, length: 200_000), on: "b")
        try session.place(Clip(id: "M", file: "g", start: 0, offset: 0, length: 200_000), on: "s")
        try marker("before", at: 24_000)
        try marker("inside", at: 60_000)
        try marker("after", at: 144_000)
        let music = lane("s")
        try session.rippleDelete(48_000..<96_000, on: ["a", "b"])
        #expect(position("before") == 24_000, "a marker before R stays")
        #expect(position("inside") == 48_000, "a marker inside R goes to R.start")
        #expect(position("after") == 96_000, "a marker after R moves left by the length of R")
        #expect(lane("s") == music, "the music clips do not change")
        #expect(lane("b").map(\.start) == [0, 48_000], "the guest closes the gap")
    }

    /// C4. Control: an insert that moves the marker at 59 999 to 83 999.
    @Test mutating func rippleInsertPushesTheLaterClipsAndMarkers() throws {
        try session.place(Clip(id: "A", file: "f", start: 0, offset: 0, length: 96_000), on: "a")
        try session.place(Clip(id: "B", file: "f", start: 120_000, offset: 120_000, length: 48_000), on: "a")
        try session.place(Clip(id: "C", file: "f", start: 60_000, offset: 0, length: 40_000), on: "b")
        try session.place(Clip(id: "G", file: "g", start: 0, offset: 0, length: 100_000), on: "s")
        try marker("before", at: 59_999)
        try marker("at", at: 60_000)
        let music = lane("s")
        try session.rippleInsert(24_000, at: 60_000, on: ["a", "b"])
        #expect(
            lane("a") == [
                Clip(id: "A", file: "f", start: 0, offset: 0, length: 60_000),
                Clip(id: "A@60000", file: "f", start: 84_000, offset: 60_000, length: 36_000),
                Clip(id: "B", file: "f", start: 144_000, offset: 120_000, length: 48_000),
            ], "the clip that holds 60 000 splits there, and the later clips move right")
        #expect(
            lane("b") == [Clip(id: "C", file: "f", start: 84_000, offset: 0, length: 40_000)],
            "a clip at the insert frame moves right")
        #expect(lane("s") == music, "track s is out of scope")
        #expect(position("before") == 59_999, "a marker before the insert frame stays")
        #expect(position("at") == 84_000, "a marker at the insert frame moves right")
    }

    /// C4 limit. Control: an end check that allows the end past `Frames.limit`, or one that moves
    /// some clips before it throws.
    @Test mutating func anInsertPastTheLimitChangesNothing() throws {
        try session.place(Clip(id: "A", file: "f", start: 0, offset: 0, length: 48_000), on: "a")
        try session.place(Clip(id: "Z", file: "f", start: Frames.limit - 48_000, offset: 0, length: 24_000), on: "a")
        var passing = session
        try passing.rippleInsert(24_000, at: 0, on: ["a"])
        #expect(passing.track("a")?.clips.last?.end == Frames.limit, "a clip end at Frames.limit passes")
        let before = session
        #expect(throws: SessionError.frameOutOfRange, "a clip end at Frames.limit + 1 is refused") {
            try session.rippleInsert(24_001, at: 0, on: ["a"])
        }
        #expect(session == before, "a refused insert changes nothing")
    }

    /// C4 marker limit (plan gate 1 item 4). Control: a marker past the limit that is written, or a
    /// clip that moves before the marker check throws.
    @Test mutating func aMarkerPastTheLimitChangesNothing() throws {
        try session.place(Clip(id: "A", file: "f", start: 0, offset: 0, length: 48_000), on: "a")
        try marker("late", at: Frames.limit - 24_000)
        var passing = session
        try passing.rippleInsert(24_000, at: 0, on: ["a"])
        #expect(passing.markers["late"]?.position == Frames.limit, "a marker at Frames.limit passes")
        let before = session
        #expect(throws: SessionError.frameOutOfRange, "a marker at Frames.limit + 1 is refused") {
            try session.rippleInsert(24_001, at: 0, on: ["a"])
        }
        #expect(session == before, "a refused insert moves no clip and no marker")
    }

    /// An empty range, a length of 0, and an empty track list change nothing. A track given twice
    /// ripples once. An unknown track and a frame out of range throw.
    @Test mutating func theEdgeCasesOfTheArguments() throws {
        try session.place(Clip(id: "A", file: "f", start: 0, offset: 0, length: 96_000), on: "a")
        try marker("m", at: 60_000)
        let before = session
        try session.rippleDelete(48_000..<48_000, on: ["a"])
        try session.rippleDelete(0..<48_000, on: [])
        try session.rippleDelete([], on: ["a"])
        try session.rippleInsert(0, at: 0, on: ["a"])
        try session.rippleInsert(48_000, at: 0, on: [])
        #expect(session == before, "no edit with nothing to ripple")
        #expect(throws: SessionError.unknownTrack("x")) { try session.rippleDelete(0..<10, on: ["a", "x"]) }
        #expect(throws: SessionError.unknownTrack("x")) { try session.rippleInsert(10, at: 0, on: ["a", "x"]) }
        #expect(throws: SessionError.frameOutOfRange) { try session.rippleDelete(-1..<10, on: ["a"]) }
        #expect(throws: SessionError.frameOutOfRange) { try session.rippleInsert(-1, at: 0, on: ["a"]) }
        #expect(throws: SessionError.frameOutOfRange) { try session.rippleInsert(10, at: -1, on: ["a"]) }
        // The order of the checks: the frames, then the tracks, then nothing to ripple.
        #expect(throws: SessionError.unknownTrack("x")) { try session.rippleDelete(48_000..<48_000, on: ["x"]) }
        #expect(throws: SessionError.frameOutOfRange) { try session.rippleDelete(-1..<10, on: ["x"]) }
        #expect(throws: SessionError.unknownTrack("x")) { try session.rippleDelete([], on: ["x"]) }
        #expect(session == before, "a refused ripple changes nothing")
        try session.rippleDelete(0..<12_000, on: ["a", "a"])
        #expect(lane("a") == [Clip(id: "A", file: "f", start: 0, offset: 12_000, length: 84_000)], "one ripple")
        #expect(position("m") == 48_000, "the marker moves once")
    }

    /// Clips P and Q on track "a" with a crossfade of 960 at their join J = 120 000 (one file, not
    /// seamless, with handles), and clip K at 0..<30 000.
    mutating func crossfadeJoin() throws {
        try session.place(Clip(id: "K", file: "f", start: 0, offset: 300_000, length: 30_000), on: "a")
        try session.place(Clip(id: "P", file: "f", start: 100_000, offset: 0, length: 20_000), on: "a")
        try session.place(Clip(id: "Q", file: "f", start: 120_000, offset: 200_000, length: 20_000), on: "a")
        try session.setCrossfades(["P": 960])
    }

    /// C5. Control: a shift that drops each crossfade it moves, or a repair that leaves one on one clip.
    @Test mutating func aRippleKeepsTheCrossfadesThatMoveWhole() throws {
        try crossfadeJoin()
        let joined: [ClipID: Crossfades] = ["P": Crossfades(start: 0, end: 960)!, "Q": Crossfades(start: 960, end: 0)!]
        try session.rippleDelete(10_000..<20_000, on: ["a"])
        #expect(allCrossfades == joined, "a ripple delete before the join keeps its crossfade")
        #expect(lane("a").map(\.start) == [0, 10_000, 90_000, 110_000])
        try session.rippleInsert(5_000, at: 50_000, on: ["a"])
        #expect(allCrossfades == joined, "a ripple insert before the join keeps its crossfade")
        #expect(lane("a").map(\.start) == [0, 10_000, 95_000, 115_000])
        #expect(try Session(xml: try session.checkedData()) == session, "the session reads back")
    }

    /// C5. Control: a crossfade left on one clip (the save throws `.crossfadeWithoutJoin`).
    @Test(arguments: ["delete from the join", "delete to the join", "insert at the join"])
    func aRippleDropsTheCrossfadeAtItsEdge(edit: String) throws {
        var test = try RippleTests()
        try test.crossfadeJoin()
        switch edit {
        case "delete from the join": try test.session.rippleDelete(120_000..<125_000, on: ["a"])
        case "delete to the join": try test.session.rippleDelete(115_000..<120_000, on: ["a"])
        default: try test.session.rippleInsert(1_000, at: 120_000, on: ["a"])
        }
        #expect(test.allCrossfades.isEmpty, "\(edit): the crossfade goes from both clips")
        #expect((try? Session(xml: try test.session.checkedData())) == test.session, "\(edit): the session reads back")
    }

    /// C18. Control: a version above 1.
    @Test mutating func aRippleKeepsTheFileVersion() throws {
        try session.place(Clip(id: "A", file: "f", start: 0, offset: 0, length: 96_000), on: "a")
        try session.place(Clip(id: "G", file: "g", start: 0, offset: 0, length: 96_000), on: "s")
        try session.rippleDelete(12_000..<24_000, on: ["a", "b", "s"])
        #expect(session.fileVersion == 1, "after a ripple delete")
        try session.rippleInsert(12_000, at: 6_000, on: ["a", "b", "s"])
        #expect(session.fileVersion == 1, "after a ripple insert")
    }
}
