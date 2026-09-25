import DirigibleCore
import Testing

/// Edit-commands criteria 1 to 4, with literal frames. Tracks "a" and "b" are mono, "s" is stereo.
/// File "f" is mono and "g" is stereo, 480 000 frames each. Clip "A" is on "a" at 0..<48 000,
/// clip "C" is on "b" at 90 000..<150 000, and clip "G" is on "s" at 0..<48 000.
struct ExcerptPasteTests {
    var session: Session

    init() throws {
        session = try editFixture()
        try session.place(Clip(id: "A", file: "f", start: 0, offset: 0, length: 48_000), on: "a")
        try session.place(Clip(id: "C", file: "f", start: 90_000, offset: 0, length: 60_000), on: "b")
        try session.place(Clip(id: "G", file: "g", start: 0, offset: 0, length: 48_000), on: "s")
    }

    func lane(_ track: TrackID) -> [Clip] {
        session.track(track).map { Array($0.clips) } ?? []
    }

    /// Control: an excerpt that keeps the timeline start gives start 12 000.
    @Test func anExcerptCutsTheEdgeClipsAndKeepsTheGap() throws {
        let excerpt = try session.excerpt(of: 12_000..<36_000, on: ["a"])
        #expect(excerpt.length == 24_000)
        #expect(excerpt.lanes.map(\.source) == ["a"])
        #expect(excerpt.lanes.first?.clips == [Clip(id: "A", file: "f", start: 0, offset: 12_000, length: 24_000)])

        let gap = try session.excerpt(of: 40_000..<100_000, on: ["a", "b"])
        #expect(gap.length == 60_000)
        #expect(gap.lanes.map(\.source) == ["a", "b"])
        #expect(
            gap.lanes.map(\.clips) == [
                [Clip(id: "A", file: "f", start: 0, offset: 40_000, length: 8_000)],
                [Clip(id: "C", file: "f", start: 50_000, offset: 0, length: 10_000)],
            ])
        #expect(throws: SessionError.unknownTrack("x")) { try session.excerpt(of: 0..<10, on: ["x"]) }
        #expect(throws: SessionError.frameOutOfRange) { try session.excerpt(of: -1..<10, on: ["a"]) }
        #expect(throws: SessionError.frameOutOfRange) {
            try session.excerpt(of: 0..<(Frames.limit + 1), on: ["a"])
        }
    }

    /// Controls: a clear only under the pasted clips keeps "C" at 90 000 in the gap case; a clear
    /// on every track cuts "S" on track "s".
    @Test mutating func aPasteClearsTheBlockAndDerivesIDs() throws {
        let excerpt = try session.excerpt(of: 12_000..<36_000, on: ["a"])
        try session.place(Clip(id: "S", file: "g", start: 100_000, offset: 0, length: 10_000), on: "s")
        let untouched = (lane("a"), lane("s"))
        let pasted = try session.paste(excerpt, at: 96_000, on: ["b"])
        #expect(pasted == ["A@96000"])
        #expect(
            lane("b") == [
                Clip(id: "C", file: "f", start: 90_000, offset: 0, length: 6_000),
                Clip(id: "A@96000", file: "f", start: 96_000, offset: 12_000, length: 24_000),
                Clip(id: "C@120000", file: "f", start: 120_000, offset: 30_000, length: 30_000),
            ])
        #expect(lane("a") == untouched.0 && lane("s") == untouched.1)

        // The excerpt 20 000..<100 000 of "a" has one clip part and a gap of 52 000 frames at its end.
        // The paste at 100 000 clears 100 000..<180 000 on "b", also under that gap.
        let withGap = try session.excerpt(of: 20_000..<100_000, on: ["a"])
        try session.paste(withGap, at: 100_000, on: ["b"])
        #expect(
            lane("b") == [
                Clip(id: "C", file: "f", start: 90_000, offset: 0, length: 6_000),
                Clip(id: "A@96000", file: "f", start: 96_000, offset: 12_000, length: 4_000),
                Clip(id: "A@100000", file: "f", start: 100_000, offset: 20_000, length: 28_000),
            ])
        #expect(lane("a") == untouched.0)
    }

    /// Control: a pasted clip that keeps its source ID gives "A" twice.
    @Test mutating func twoPastesAtOneFrameGetTwoFreeIDs() throws {
        let twice = try session.excerpt(of: 12_000..<36_000, on: ["a", "a"])
        #expect(try session.paste(twice, at: 96_000, on: ["a", "b"]) == ["A@96000", "A@96000-2"])
        #expect(lane("a").map(\.id) == ["A", "A@96000"])
        #expect(lane("b").map(\.id) == ["C", "A@96000-2", "C@120000"])
    }

    @Test mutating func aPasteRefusesAStereoLaneOnAMonoTrack() throws {
        let stereo = try session.excerpt(of: 0..<10_000, on: ["s"])
        let before = session
        #expect(throws: SessionError.layoutMismatch("b", .file("g"))) {
            try session.paste(stereo, at: 0, on: ["b"])
        }
        #expect(session == before)
    }

    @Test mutating func aPasteRefusesAnEndPastTheLimit() throws {
        let excerpt = try session.excerpt(of: 12_000..<36_000, on: ["a"])
        let before = session
        #expect(throws: SessionError.frameOutOfRange) {
            try session.paste(excerpt, at: Frames.limit - 10_000, on: ["b"])
        }
        #expect(throws: SessionError.frameOutOfRange) { try session.paste(excerpt, at: -1, on: ["b"]) }
        #expect(session == before)
    }

    @Test mutating func aPasteRefusesAFileThatIsNotInThePool() throws {
        try session.addFile(AudioFile(id: "h", path: "h.wav", layout: .mono, length: 1_000))
        try session.place(Clip(id: "H", file: "h", start: 200_000, offset: 0, length: 1_000), on: "a")
        let excerpt = try session.excerpt(of: 200_000..<201_000, on: ["a"])
        try session.clear(200_000..<201_000, on: "a")
        try session.removeFile("h")
        let before = session
        #expect(throws: SessionError.unknownFile("h")) { try session.paste(excerpt, at: 0, on: ["b"]) }
        #expect(session == before)
    }

    @Test mutating func aPasteRefusesATrackCountThatIsNotTheLaneCount() throws {
        let excerpt = try session.excerpt(of: 12_000..<36_000, on: ["a"])
        let before = session
        #expect(throws: SessionError.trackCount(1)) { try session.paste(excerpt, at: 0, on: ["a", "b"]) }
        #expect(throws: SessionError.trackCount(1)) { try session.paste(excerpt, at: 0, on: []) }
        #expect(session == before)
    }

    @Test mutating func aPasteRefusesATrackGivenTwiceAndAnUnknownTrack() throws {
        let twice = try session.excerpt(of: 12_000..<36_000, on: ["a", "a"])
        let before = session
        #expect(throws: SessionError.duplicateID("b")) { try session.paste(twice, at: 0, on: ["b", "b"]) }
        #expect(throws: SessionError.unknownTrack("x")) { try session.paste(twice, at: 0, on: ["b", "x"]) }
        #expect(session == before)
    }

    /// Control: a sum of `at` and the length before the range check traps with an overflow.
    @Test mutating func aPasteAtIntMaxRefusesAndDoesNotTrap() throws {
        let excerpt = try session.excerpt(of: 12_000..<36_000, on: ["a"])
        let before = session
        #expect(throws: SessionError.frameOutOfRange) { try session.paste(excerpt, at: Frames(.max), on: ["b"]) }
        #expect(session == before)
    }
}

/// Tracks "a" and "b" (mono) and "s" (stereo); files "f" (mono) and "g" (stereo), 480 000 frames each.
func editFixture() throws -> Session {
    var session = Session(sampleRate: 48_000)
    try session.addFile(AudioFile(id: "f", path: "f.wav", layout: .mono, length: 480_000))
    try session.addFile(AudioFile(id: "g", path: "g.wav", layout: .stereo, length: 480_000))
    try session.addTrack("a", name: "A", layout: .mono)
    try session.addTrack("b", name: "B", layout: .mono)
    try session.addTrack("s", name: "S", layout: .stereo)
    return session
}
