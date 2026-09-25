import DirigibleCore
import Testing

/// Edit-commands criterion 5. Clip "A" is on "a" at 0..<100 000, clip "B" is on "b" at
/// 50 000..<70 000, and a stereo clip with the ID "A@60000" is on "s".
struct SplitClipsTests {
    var session: Session

    init() throws {
        session = try editFixture()
        try session.place(Clip(id: "A", file: "f", start: 0, offset: 0, length: 100_000), on: "a")
        try session.place(Clip(id: "B", file: "f", start: 50_000, offset: 0, length: 20_000), on: "b")
        try session.place(Clip(id: "A@60000", file: "g", start: 0, offset: 0, length: 1_000), on: "s")
    }

    func lane(_ track: TrackID) -> [Clip] {
        session.track(track).map { Array($0.clips) } ?? []
    }

    /// Control: ascending order splits "A@20000" at 60 000 and gives "A@20000@60000".
    @Test(arguments: [[Frames(60_000), 20_000], [20_000, 60_000]])
    mutating func framesGoInDescendingOrder(frames: [Frames]) throws {
        #expect(try session.splitClips(at: frames, on: ["a", "b"]) == ["A@60000-2", "A@20000", "B@60000"])
        #expect(
            lane("a") == [
                Clip(id: "A", file: "f", start: 0, offset: 0, length: 20_000),
                Clip(id: "A@20000", file: "f", start: 20_000, offset: 20_000, length: 40_000),
                Clip(id: "A@60000-2", file: "f", start: 60_000, offset: 60_000, length: 40_000),
            ])
        #expect(
            lane("b") == [
                Clip(id: "B", file: "f", start: 50_000, offset: 0, length: 10_000),
                Clip(id: "B@60000", file: "f", start: 60_000, offset: 10_000, length: 10_000),
            ])
    }

    /// Control: a split at `start <= frame` splits "A" at its start frame 0.
    @Test mutating func anEdgeOrAGapDoesNothing() throws {
        let before = session
        #expect(try session.splitClips(at: [0, 100_000, 200_000], on: ["a", "b"]) == [])
        #expect(try session.splitClips(at: [50_000, 70_000], on: ["b"]) == [])
        #expect(try session.splitClips(at: [60_000], on: []) == [])
        #expect(session == before)
        #expect(throws: SessionError.unknownTrack("x")) { try session.splitClips(at: [60_000], on: ["a", "x"]) }
        #expect(session == before)
    }

    @Test mutating func equalsSingleSplitsInDescendingOrder() throws {
        var single = session
        try single.split("A", at: 60_000)
        try single.split("A", at: 20_000)
        try single.split("B", at: 60_000)
        try session.splitClips(at: [20_000, 60_000], on: ["a", "b"])
        #expect(session == single)
    }
}
