import Testing

@testable import DirigibleCore

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

/// Multi-clip-selection criteria C7 to C9: a nudge with a lane offset. Tracks t1, t2, t3 (mono)
/// and st (stereo); files f and h (mono). "A" (file f) and "B" (file h) join on t1 at 1 000 and
/// 5 000; "W" is on t2 at 0..<10 000.
struct NudgeLanesTests {
    var session: Session

    init() throws {
        session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f", path: "f.wav", layout: .mono, length: 480_000))
        try session.addFile(AudioFile(id: "h", path: "h.wav", layout: .mono, length: 480_000))
        for (id, layout) in [("t1", ChannelLayout.mono), ("t2", .mono), ("t3", .mono), ("st", .stereo)] {
            try session.addTrack(TrackID(id), name: id, layout: layout)
        }
        try session.place(Clip(id: "A", file: "f", start: 1_000, offset: 1_000, length: 4_000), on: "t1")
        try session.place(Clip(id: "B", file: "h", start: 5_000, offset: 1_000, length: 4_000), on: "t1")
        try session.place(Clip(id: "W", file: "h", start: 0, offset: 0, length: 10_000), on: "t2")
    }

    func lane(_ track: TrackID) -> [Clip] { session.track(track).map { Array($0.clips) } ?? [] }

    /// C7: "A" goes to t2, where "W" also moves away to t3. Control: a loop that takes out and puts
    /// in one lane at a time cuts "W" with "A" before "W" moves.
    @Test mutating func aLaneOffsetMovesClipsOutBeforeTheyGoIn() throws {
        try session.nudge(["A", "W"], by: 2_000, lanes: 1)
        #expect(lane("t1") == [Clip(id: "B", file: "h", start: 5_000, offset: 1_000, length: 4_000)])
        #expect(lane("t2") == [Clip(id: "A", file: "f", start: 3_000, offset: 1_000, length: 4_000)])
        #expect(lane("t3") == [Clip(id: "W", file: "h", start: 2_000, offset: 0, length: 10_000)])
    }

    /// C7a: a moved clip overwrites the unselected clip under it, as a single drop does.
    @Test mutating func aMovedClipOverwritesAnUnselectedClip() throws {
        try session.nudge(["B"], by: 0, lanes: 1)
        #expect(
            lane("t2") == [
                Clip(id: "W", file: "h", start: 0, offset: 0, length: 5_000),
                Clip(id: "B", file: "h", start: 5_000, offset: 1_000, length: 4_000),
                Clip(id: "W@9000", file: "h", start: 9_000, offset: 9_000, length: 1_000),
            ])
    }

    /// C8: a join that moves whole keeps its crossfade.
    @Test mutating func aJoinThatMovesTogetherKeepsItsCrossfade() throws {
        try session.setCrossfades(["A": 960])
        try session.nudge(["A", "B"], by: 20_000, lanes: 2)
        #expect(lane("t3").map(\.crossfades) == [Crossfades(start: 0, end: 960), Crossfades(start: 960, end: 0)])
        #expect((try? session.checkedData()) != nil, "the session saves")
    }

    /// C8 and C9: a lane change with no time change moves the clip, and the broken join drops the
    /// crossfade from both clips. Control: the early return of an offset of 0 keeps "A" on t1.
    @Test mutating func aZeroOffsetWithOneLaneMovesTheClipsAndDropsABrokenCrossfade() throws {
        try session.setCrossfades(["A": 960])
        try session.nudge(["A"], by: 0, lanes: 2)
        #expect(lane("t1") == [Clip(id: "B", file: "h", start: 5_000, offset: 1_000, length: 4_000)])
        #expect(lane("t3") == [Clip(id: "A", file: "f", start: 1_000, offset: 1_000, length: 4_000)])
        #expect((try? session.checkedData()) != nil, "the session saves")
    }

    @Test mutating func aLaneOffsetPastTheLastTrackThrowsAndChangesNothing() throws {
        let before = session
        #expect(throws: SessionError.laneOutOfRange("W")) { try session.nudge(["W"], by: 0, lanes: 3) }
        #expect(throws: SessionError.laneOutOfRange("A")) { try session.nudge(["A"], by: 100, lanes: -1) }
        #expect(throws: SessionError.laneOutOfRange("A")) { try session.nudge(["A"], by: 0, lanes: .max) }
        #expect(throws: SessionError.laneOutOfRange("A")) { try session.nudge(["A"], by: 0, lanes: .min) }
        #expect(session == before)
    }

    @Test mutating func aLayoutMismatchThrowsAndChangesNothing() throws {
        let before = session
        #expect(throws: SessionError.layoutMismatch("st", .file("f"))) {
            try session.nudge(["A"], by: 0, lanes: 3)
        }
        #expect(session == before)
    }

    @Test mutating func zeroOffsetAndZeroLanesChangesNothing() throws {
        try session.setCrossfades(["A": 960])
        let before = session
        try session.nudge(["A"], by: 0, lanes: 0)
        #expect(session == before)
        #expect(throws: SessionError.unknownClip("x")) { try session.nudge(["x"], by: 0, lanes: 1) }
        #expect(session == before)
    }
}
