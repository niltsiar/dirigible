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
        try session.clear(200_000..<201_000, on: ["a"])
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

    /// A track given twice is a wrong target count, not a used ID (code gate 1 item 6).
    @Test mutating func aPasteRefusesATrackGivenTwiceAndAnUnknownTrack() throws {
        let twice = try session.excerpt(of: 12_000..<36_000, on: ["a", "a"])
        let before = session
        #expect(throws: SessionError.trackCount(2)) { try session.paste(twice, at: 0, on: ["b", "b"]) }
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

    /// Decision 0042, C2: the file ID "f" of another pool names other audio here, so the paste
    /// refuses. Control: a check that the ID is in `files` pastes on the wrong audio.
    @Test mutating func aPasteRefusesAFileRecordOfAnotherPool() throws {
        let excerpt = try session.excerpt(of: 0..<48_000, on: ["a"])
        var other = Session(sampleRate: 48_000)
        try other.addFile(AudioFile(id: "f", path: "f.wav", layout: .mono, length: 48_000))
        try other.addTrack("a", name: "A", layout: .mono)
        let before = other

        #expect(throws: SessionError.foreignFile("f")) { try other.paste(excerpt, at: 0, on: ["a"]) }
        #expect(other == before)

        // The same pool pastes, also after an unrelated file joins it.
        try session.addFile(AudioFile(id: "h", path: "h.wav", layout: .mono, length: 1_000))
        #expect(try session.paste(excerpt, at: 100_000, on: ["b"]) == ["A@100000"])
        // A file that an undo removed is unknown, as before.
        var empty = Session(sampleRate: 48_000)
        try empty.addTrack("a", name: "A", layout: .mono)
        #expect(throws: SessionError.unknownFile("f")) { try empty.paste(excerpt, at: 0, on: ["a"]) }
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

/// Clip-set-clipboard C1 to C5 (decision 0038). Tracks t1, t2 (mono, or the stereo "s"), and t3.
/// The set clips: A on t1 at 48 000..<96 000 and C on t3 at 144 000..<192 000. B on t1 at
/// 96 000..<144 000 is not in the set.
extension ExcerptPasteTests {
    static func setFixture(middle: TrackID = "t2") throws -> Session {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f", path: "f.wav", layout: .mono, length: 480_000))
        try session.addTrack("t1", name: "T1", layout: .mono)
        try session.addTrack(middle, name: "M", layout: middle == "s" ? .stereo : .mono)
        try session.addTrack("t3", name: "T3", layout: .mono)
        for (id, start, track) in [("A", 48_000, "t1"), ("B", 96_000, "t1"), ("C", 144_000, "t3")] {
            try session.place(
                Clip(id: ClipID(id), file: "f", start: Frames(start), offset: Frames(start), length: 48_000),
                on: TrackID(track))
        }
        return session
    }

    /// C1. Control: the hull range excerpt holds B.
    @Test func aClipSetExcerptKeepsOffsetsAndEmptyLanes() throws {
        let session = try Self.setFixture()
        let excerpt = try session.excerpt(of: ["A", "C"])
        #expect(excerpt.kind == .clips && excerpt.length == 144_000)
        #expect(excerpt.lanes.map(\.source) == ["t1", "t2", "t3"])
        #expect(
            excerpt.lanes.map(\.clips) == [
                [Clip(id: "A", file: "f", start: 0, offset: 48_000, length: 48_000)], [],
                [Clip(id: "C", file: "f", start: 96_000, offset: 144_000, length: 48_000)],
            ])
        #expect(try session.excerpt(of: ["C", "A"]) == excerpt, "the ID order does not change the excerpt")
        let hull = try session.excerpt(of: 48_000..<192_000, on: ["t1", "t2", "t3"])
        #expect(hull.kind == .range && hull.lanes[0].clips.map(\.id) == ["A", "B"], "the control holds B")
    }

    /// C2. Control: a clear of the whole block removes D on t2 and all of E on t3.
    @Test func aClipSetPasteOverwritesOnlyUnderItsClips() throws {
        var session = try Self.setFixture()
        let excerpt = try session.excerpt(of: ["A", "C"])
        try session.place(Clip(id: "D", file: "f", start: 500_000, offset: 0, length: 100_000), on: "t2")
        try session.place(Clip(id: "E", file: "f", start: 560_000, offset: 0, length: 40_000), on: "t3")

        #expect(try session.paste(excerpt, at: 480_000, on: ["t1", "t2", "t3"]) == ["A@480000", "C@576000"])

        func lane(_ track: TrackID) -> [Clip] { session.track(track).map { Array($0.clips) } ?? [] }
        #expect(lane("t1").map(\.id) == ["A", "B", "A@480000"])
        #expect(lane("t1").last == Clip(id: "A@480000", file: "f", start: 480_000, offset: 48_000, length: 48_000))
        #expect(lane("t2") == [Clip(id: "D", file: "f", start: 500_000, offset: 0, length: 100_000)], "D stays whole")
        #expect(
            lane("t3") == [
                Clip(id: "C", file: "f", start: 144_000, offset: 144_000, length: 48_000),
                Clip(id: "E", file: "f", start: 560_000, offset: 0, length: 16_000),
                Clip(id: "C@576000", file: "f", start: 576_000, offset: 144_000, length: 48_000),
            ])
    }

    /// C3 and the empty list of C12c.
    @Test func aClipSetExcerptRefusesAnUnknownClip() throws {
        var session = try Self.setFixture()
        #expect(throws: SessionError.unknownClip("nope")) { try session.excerpt(of: ["A", "nope"]) }
        let empty = try session.excerpt(of: [])
        #expect(empty.kind == .clips && empty.length == 0 && empty.lanes.isEmpty)
        let before = session
        #expect(try session.paste(empty, at: 0, on: []) == [])
        #expect(session == before)
    }

    /// C3: a refused set paste changes nothing.
    @Test func aClipSetPasteRefusesAndChangesNothing() throws {
        var session = try Self.setFixture()
        let excerpt = try session.excerpt(of: ["A", "C"])
        let before = session
        #expect(throws: SessionError.trackCount(3)) { try session.paste(excerpt, at: 0, on: ["t2", "t3"]) }
        #expect(throws: SessionError.frameOutOfRange) {
            try session.paste(excerpt, at: Frames.limit, on: ["t1", "t2", "t3"])
        }
        #expect(session == before)
    }

    /// C4 (decision 0036): P and Q join with a 20 ms crossfade, and Q joins R (not in the set) with
    /// one. Control: a paste with no join repair keeps the crossfade of Q@448000 to no clip.
    @Test func aClipSetPasteKeepsAJoinedCrossfadeAndDropsAnOrphan() throws {
        var session = try Self.setFixture()
        for (id, start, offset) in [("P", 200_000, 10_000), ("Q", 248_000, 100_000), ("R", 296_000, 300_000)] {
            try session.place(
                Clip(id: ClipID(id), file: "f", start: Frames(start), offset: Frames(offset), length: 48_000), on: "t2")
        }
        try session.setCrossfades(["P": 960, "Q": 960])
        let excerpt = try session.excerpt(of: ["P", "Q"])

        try session.paste(excerpt, at: 400_000, on: ["t2"])

        #expect(session.clip("P@400000")?.clip.crossfades == Crossfades(start: 0, end: 960))
        #expect(session.clip("Q@448000")?.clip.crossfades == Crossfades(start: 960, end: 0), "the orphan goes")
        #expect(session.clip("Q")?.clip.crossfades == Crossfades(start: 960, end: 960), "the source keeps it")
    }

    /// C5: an empty lane passes over a track of the other layout; a set clip onto it refuses.
    @Test func aClipSetPasteOverATrackOfTheOtherLayout() throws {
        var session = try Self.setFixture(middle: "s")
        let excerpt = try session.excerpt(of: ["A", "C"])
        #expect(excerpt.lanes.map(\.source) == ["t1", "s", "t3"] && excerpt.lanes[1].clips.isEmpty)
        #expect(try session.paste(excerpt, at: 480_000, on: ["t1", "s", "t3"]) == ["A@480000", "C@576000"])
        let before = session
        #expect(throws: SessionError.layoutMismatch("s", .file("f"))) {
            try session.paste(try session.excerpt(of: ["A"]), at: 0, on: ["s"])
        }
        #expect(session == before)
    }
}
