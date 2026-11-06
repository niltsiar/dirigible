import DirigibleCore
import Testing

@testable import DirigibleTimeline

/// The target rule of Roll Edit to Playhead (C12, decision 0036). 48 kHz. Track t1 holds P at
/// 0 ..< 48,000, C at 48,000 ..< 96,000, and N at 96,000 ..< 144,000, all touching. Track t2 holds
/// Q at 0 ..< 48,000 and R at 48,000 ..< 96,000, then a gap, then S at 120,000 ..< 168,000. Track t3
/// holds one clip, U at 0 ..< 48,000, with no neighbor. File fa is 480,000 frames long and every clip
/// starts at the file offset 96,000, so each clip has room to grow on both sides. File fs is 48,000
/// frames long and holds P2 below.
struct SelectionTrimTests {
    let session: Session

    init() throws {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "fa", path: "fa.wav", layout: .mono, length: 480_000))
        try session.addFile(AudioFile(id: "fs", path: "fs.wav", layout: .mono, length: 48_000))
        for n in 1...3 { try session.addTrack(TrackID("t\(n)"), name: "T\(n)", layout: .mono) }
        for (id, track, start) in [
            ("P", "t1", 0), ("C", "t1", 48_000), ("N", "t1", 96_000), ("Q", "t2", 0), ("R", "t2", 48_000),
            ("S", "t2", 120_000), ("U", "t3", 0),
        ] as [(ClipID, TrackID, Int)] {
            try session.place(
                Clip(id: id, file: "fa", start: Frames(start), offset: Frames(start + 96_000), length: 48_000),
                on: track)
        }
        self.session = session
    }

    func joins(_ playhead: Frames, _ selection: Selection) -> [String] {
        selection.rollJoins(to: playhead, in: session).map { "\($0.left)\($0.by.count < 0 ? "" : "+")\($0.by.count)" }
    }

    func on(_ tracks: TrackID...) -> Selection { .range(Marks(tracks: Set(tracks))) }

    /// C12. The playhead in C is nearer to the join before C at 60,000 and nearer to the join after C
    /// at 90,000. Control: a rule that always takes the join before the clip fails the second case.
    @Test func rollJoinsPickTheNearerJoin() {
        #expect(joins(60_000, on("t1")) == ["P+12000"], "the join before C rolls right")
        #expect(joins(90_000, on("t1")) == ["C-6000"], "the join after C rolls left")
        #expect(joins(72_000, on("t1")) == ["P+24000"], "a tie takes the join before the clip")
    }

    /// C12. Only a join that touches a neighbor can roll: R has a join before it and none after it
    /// (the gap), and S has none.
    @Test func aClipWithOneJoinRollsThatJoin() {
        #expect(joins(90_000, on("t2")) == ["Q+42000"], "the join after R does not exist, so the join before rolls")
        #expect(joins(130_000, on("t2")).isEmpty, "S has no neighbor that touches it")
        #expect(joins(20_000, on("t3")).isEmpty, "U has no neighbor")
    }

    /// C12. The playhead in a gap, at a join, or past the last clip gives no roll.
    @Test func noRollInAGapAtAJoinOrPastTheEnd() {
        #expect(joins(110_000, on("t2")).isEmpty, "in the gap between R and S")
        #expect(joins(48_000, on("t1")).isEmpty, "at the join of P and C: the delta is 0")
        #expect(joins(144_000, on("t1")).isEmpty, "past the end of N")
    }

    /// C12. A track whose delta is outside `Session.rollLimits` skips, and the others roll.
    @Test func aTrackPastItsLimitIsSkipped() throws {
        var session = session
        try session.removeClips(["Q"])
        try session.place(Clip(id: "Q", file: "fs", start: 0, offset: 0, length: 48_000), on: "t2")
        let selection = Selection.range(Marks(tracks: ["t1", "t2"]))
        #expect(session.rollLimits("Q")?.upperBound == .zero, "Q is at the end of its file")
        #expect(
            selection.rollJoins(to: 60_000, in: session).map { "\($0.left) \($0.by.count)" } == ["P 12000"],
            "t2 would roll Q by 12,000 and skips")
    }

    /// C12. A range takes its tracks, a clip set takes the tracks of its clips, and no selected track
    /// takes all tracks.
    @Test func theSelectionPicksTheTracks() throws {
        let both = joins(60_000, on("t1", "t2"))
        #expect(both == ["P+12000", "Q+12000"])
        #expect(joins(60_000, .none) == both, "no selected track: all tracks")
        #expect(joins(60_000, .range(Marks(inPoint: 0, outPoint: 1_000))) == both, "a range with no track too")
        let set = try #require(ClipSet(["R"]))
        #expect(joins(60_000, .clips(set)) == ["Q+12000"], "the track of the selected clip")
        #expect(joins(60_000, on("t3")).isEmpty, "t3 has no clip at the playhead that rolls")
    }
}
