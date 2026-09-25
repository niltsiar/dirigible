import DirigibleCore
import Testing

/// Edit-commands criterion 6. Track "a" has "A" at 0..<10 000, "B" at 10 000..<20 000, and "N"
/// at 20 000..<40 000. Track "b" has "W" at 0..<50 000 and "M" at 60 000..<70 000.
struct NudgeTests {
    var session: Session

    init() throws {
        session = try editFixture()
        try session.place(Clip(id: "A", file: "f", start: 0, offset: 0, length: 10_000), on: "a")
        try session.place(Clip(id: "B", file: "f", start: 10_000, offset: 10_000, length: 10_000), on: "a")
        try session.place(Clip(id: "N", file: "f", start: 20_000, offset: 20_000, length: 20_000), on: "a")
        try session.place(Clip(id: "W", file: "f", start: 0, offset: 0, length: 50_000), on: "b")
        try session.place(Clip(id: "M", file: "f", start: 60_000, offset: 0, length: 10_000), on: "b")
    }

    func lane(_ track: TrackID) -> [Clip] {
        session.track(track).map { Array($0.clips) } ?? []
    }

    /// Control: a move of one clip at a time in start order cuts "B" with the moved "A".
    @Test mutating func adjacentMovedClipsDoNotCutEachOther() throws {
        try session.nudge(["A", "B"], by: 480)
        #expect(
            lane("a") == [
                Clip(id: "A", file: "f", start: 480, offset: 0, length: 10_000),
                Clip(id: "B", file: "f", start: 10_480, offset: 10_000, length: 10_000),
                Clip(id: "N", file: "f", start: 20_480, offset: 20_480, length: 19_520),
            ])
    }

    @Test mutating func anUnmovedNeighborIsCut() throws {
        try session.nudge(["M"], by: -30_000)
        #expect(
            lane("b") == [
                Clip(id: "W", file: "f", start: 0, offset: 0, length: 30_000),
                Clip(id: "M", file: "f", start: 30_000, offset: 0, length: 10_000),
                Clip(id: "W@40000", file: "f", start: 40_000, offset: 40_000, length: 10_000),
            ])
    }

    @Test mutating func belowZeroThrowsAndChangesNothing() throws {
        let before = session
        #expect(throws: SessionError.frameOutOfRange) { try session.nudge(["M", "A"], by: -1) }
        #expect(throws: SessionError.frameOutOfRange) { try session.nudge(["N"], by: Frames.limit - 20_000) }
        #expect(session == before)
    }

    @Test mutating func unknownClipThrows() throws {
        let before = session
        #expect(throws: SessionError.unknownClip("x")) { try session.nudge(["A", "x"], by: 480) }
        #expect(session == before)
    }

    /// Control: a nudge that refuses a negative offset fails here.
    @Test mutating func leftMirrorsRight() throws {
        try session.nudge(["B", "N", "M"], by: -480)
        #expect(
            lane("a") == [
                Clip(id: "A", file: "f", start: 0, offset: 0, length: 9_520),
                Clip(id: "B", file: "f", start: 9_520, offset: 10_000, length: 10_000),
                Clip(id: "N", file: "f", start: 19_520, offset: 20_000, length: 20_000),
            ])
        #expect(lane("b").map(\.start) == [0, 59_520])
    }

    /// Control: a sum of the offset and a clip start before the range check traps with an overflow.
    @Test mutating func aHugeOffsetRefusesAndDoesNotTrap() throws {
        let before = session
        #expect(throws: SessionError.frameOutOfRange) { try session.nudge(["N"], by: Frames(.max)) }
        #expect(throws: SessionError.frameOutOfRange) { try session.nudge(["A"], by: Frames(.min)) }
        #expect(session == before)
    }
}
