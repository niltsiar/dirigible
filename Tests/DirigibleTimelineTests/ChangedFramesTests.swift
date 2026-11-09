import DirigibleCore
import Testing

@testable import DirigibleTimeline

/// The dirty rect of a drag event (decision 0020): the frames of the changed clips, on the small
/// fixture (A 48,000 ..< 96,000 and B 144,000 ..< 192,000 on t1, C 48,000 ..< 96,000 on t2).
struct ChangedFramesTests {
    @Test func aMoveChangesTheFramesOfItsOldAndNewPlaceAndOfTheClipsItCuts() throws {
        let session = try Fixture.session()
        var moved = session
        try moved.move("A", to: "t1", start: 72_000)
        var over = session
        try over.move("A", to: "t1", start: 150_000)

        #expect(changedFrames(from: session, to: moved)?.frames == 48_000..<120_000)
        #expect(changedFrames(from: session, to: moved)?.lanes == 0..<1, "the rows of t1 only")
        #expect(changedFrames(from: moved, to: over)?.frames == 72_000..<198_000, "B is cut to 144,000 ..< 150,000")
        #expect(changedFrames(from: session, to: session)?.frames == .zero ..< .zero)
        #expect(changedFrames(from: session, to: session)?.lanes.isEmpty == true)
        var later = session
        try later.move("B", to: "t1", start: 200_000)
        #expect(changedFrames(from: session, to: later)?.frames == 144_000..<248_000, "A before B does not change")
    }

    /// C15a (decision 0037): a ripple trim on lane 0 changes each scope lane from the edit point to
    /// the moved clips. Control: lanes 0..<1.
    @Test func aRippleChangesEveryScopeLane() throws {
        var session = try Fixture.session()
        try session.place(Clip(id: "D", file: "fb", start: 120_000, offset: 0, length: 24_000), on: "t2")
        var rippled = session
        try rippled.rippleTrim("A", edge: .end, by: 9_600, on: session.tracks.map(\.id), naming: [])
        let changed = changedFrames(from: session, to: rippled)
        #expect(changed?.lanes == 0..<2, "the rows of t1 and t2")
        #expect(
            changed.map { $0.frames.lowerBound <= 96_000 && $0.frames.upperBound >= 201_600 } == true,
            "from the old end of A to the new end of B: \(String(describing: changed?.frames))")
    }

    /// Slice 2b (decision 0037): a ripple trim moves the later region of every lane by one delta,
    /// from the first moved clip of the latest lane. Controls: a plain trim, and a marker that does
    /// not move with the clips.
    @Test func aRippleShiftsTheLaterRegion() throws {
        var session = try Fixture.session()
        try session.place(Clip(id: "D", file: "fb", start: 120_000, offset: 0, length: 24_000), on: "t2")
        try session.setMarker(Marker(id: "m", name: "m", position: 170_000, kind: .marker))
        var rippled = session
        try rippled.rippleTrim("A", edge: .end, by: 9_600, on: session.tracks.map(\.id), naming: [])
        let shift = shiftedFrames(from: session, to: rippled)
        #expect(shift?.from == 153_600 && shift?.delta == 9_600 && shift?.strays == [], "\(String(describing: shift))")
        var trimmed = session
        try trimmed.trim("A", to: 48_000..<100_000)
        #expect(shiftedFrames(from: session, to: trimmed) == nil, "a plain trim moves no later clip")
        var stuck = rippled
        try stuck.setMarker(Marker(id: "m", name: "m", position: 170_000, kind: .marker))
        #expect(shiftedFrames(from: session, to: stuck)?.strays == [179_600, 170_000], "a marker that stays")
    }

    /// C26 (decision 0020): a slip changes only the offset of one clip, and its frames redraw on its
    /// lane. A guard that compares clip ranges only gives nil.
    @Test func aSlipChangesTheClipFrames() throws {
        var session = try Fixture.session(withB: false)
        try session.place(Clip(id: "R", file: "fb", start: 96_000, offset: 48_000, length: 48_000), on: "t1")
        var slipped = session
        try slipped.slip(["R"], by: 4_800)

        #expect(changedFrames(from: session, to: slipped)?.frames == 96_000..<144_000)
        #expect(changedFrames(from: session, to: slipped)?.lanes == 0..<1)
    }

    /// C26 (decision 0020): a roll of the last two clips of a lane and a slip of the last clip
    /// move no later clip, so no region copy draws them. A rule that compares clip starts only
    /// gives a shift for the roll.
    @Test func aRollOrASlipTakesNoShift() throws {
        var session = try Fixture.session(withB: false)
        try session.place(Clip(id: "R", file: "fb", start: 96_000, offset: 48_000, length: 48_000), on: "t1")
        var rolled = session
        try rolled.roll("A", by: 4_800)
        var slipped = session
        try slipped.slip(["R"], by: 4_800)

        #expect(shiftedFrames(from: session, to: rolled) == nil)
        #expect(shiftedFrames(from: session, to: slipped) == nil)
    }

    @Test func aMoveToAnotherLaneChangesBothLanes() throws {
        let session = try Fixture.session()
        var moved = session
        try moved.move("A", to: "t2", start: 96_000)

        #expect(changedFrames(from: session, to: moved)?.frames == 48_000..<144_000)
        #expect(changedFrames(from: session, to: moved)?.lanes == 0..<2, "the rows of t1 and t2")
    }

    /// Fades C7 (decision 0035): a fade change redraws the frames of its clip on its lane only.
    @Test func aFadeChangeRedrawsItsClip() throws {
        let session = try Fixture.session()
        var faded = session
        try faded.setFades(["B": Fades(fadeIn: 4_800, fadeOut: 0)!])

        #expect(changedFrames(from: session, to: faded)?.frames == 144_000..<192_000, "the frames of B")
        #expect(changedFrames(from: session, to: faded)?.lanes == 0..<1, "the rows of t1 only")
    }

    /// R4 (run 11c-2): with a crossfade of 19,200 at J = 96,000, a gain change of A alone redraws
    /// to J + L/2 (fail value: A.end), and a change of the length redraws A.start ..< B.end.
    @Test func aCrossfadeChangesItsSoundingRange() throws {
        var session = try Fixture.session()
        try session.move("B", to: "t1", start: 96_000)
        try session.setCrossfades(["A": 19_200])
        var gain = session
        try gain.setGain(Gain(dB: -6)!, clip: "A")
        var length = session
        try length.setCrossfades(["A": 960])

        #expect(changedFrames(from: session, to: gain)?.frames == 48_000..<105_600)
        #expect(changedFrames(from: session, to: length)?.frames == 48_000..<144_000)
    }

    @Test func aChangeOutsideTheClipsRedrawsAll() throws {
        let session = try Fixture.session()
        var gain = session
        try gain.setGain(Gain(dB: -6)!, track: "t2")
        var track = session
        try track.addTrack("t4", name: "T4", layout: .mono)

        #expect(changedFrames(from: session, to: gain) == nil)
        #expect(changedFrames(from: session, to: track) == nil)
    }

    /// A marker draws one line on every lane, so a flag drag redraws the columns of its old and new
    /// position, not the lanes in view (the mouse-edits run, slice 5).
    @Test func aMarkerChangesTheFramesOfItsOldAndNewPosition() throws {
        var session = try Fixture.session()
        try session.setMarker(Marker(id: "m1", name: "M", position: 1000, kind: .marker))
        var moved = session
        try moved.setMarker(Marker(id: "m1", name: "M", position: 50_000, kind: .marker))
        var added = session
        try added.setMarker(Marker(id: "m2", name: "N", position: 300_000, kind: .chapter))
        var both = moved
        try both.move("A", to: "t1", start: 72_000)

        #expect(changedFrames(from: session, to: moved)?.frames == 1000..<50_001)
        #expect(changedFrames(from: session, to: added)?.frames == 300_000..<300_001)
        #expect(changedFrames(from: added, to: session)?.frames == 300_000..<300_001, "a removed marker")
        #expect(changedFrames(from: session, to: both)?.frames == 1000..<120_000)
        #expect(changedFrames(from: session, to: both)?.lanes == 0..<3, "a marker line crosses every lane")
    }

    /// Code gate 1 item 2: a range or a triangle drag redraws the columns where the Marks draw
    /// differently, not the lanes in view. With the same tracks, only the lines of the changed points
    /// and the band between their old and new frames change; with other tracks, both bands change.
    @Test func newMarksChangeTheFramesOfTheirChangedPointsAndBand() throws {
        let session = try Fixture.session()
        let marks = Marks(inPoint: 48_000, outPoint: 192_000, tracks: ["t1"])
        var moved = marks
        moved.inPoint = 52_800
        var other = marks
        other.tracks = ["t1", "t2"]

        #expect(changedFrames(from: marks, to: moved, in: session) == 48_000..<52_801)
        #expect(changedFrames(from: moved, to: marks, in: session) == 48_000..<52_801)
        #expect(changedFrames(from: marks, to: other, in: session) == 48_000..<192_000)
        #expect(changedFrames(from: Marks(), to: marks, in: session) == 48_000..<192_001)
        #expect(changedFrames(from: marks, to: marks, in: session) == .zero ..< .zero)
    }

    /// Z9 of run 11b-1 (plan gate H1): a handle of a clip depends on its lane neighbor (no handle
    /// at a butt join with no fade), so a change that makes or breaks a join redraws the neighbor.
    @Test func aChangeAtAButtJoinRedrawsTheNeighbor() throws {
        let session = try Fixture.session()
        var joined = session
        try joined.trim("B", to: 96_000..<192_000)
        #expect(changedFrames(from: session, to: joined)?.frames == 48_000..<192_000, "A joins the new B")
        #expect(changedFrames(from: joined, to: session)?.frames == 48_000..<192_000, "A leaves the old B")

        var split = session
        _ = try split.split("A", at: 72_000)
        var cleared = split
        try cleared.clear(72_000..<96_000, on: ["t1"])
        #expect(changedFrames(from: split, to: cleared)?.frames == 48_000..<96_000, "the left part loses its join")

        var gap = session
        try gap.trim("B", to: 96_001..<192_000)
        #expect(changedFrames(from: session, to: gap)?.frames == 96_001..<192_000, "a gap of 1 frame is no join")

        // The handle of A depends on the join only when A has no fade at that edge, and only when
        // the join comes or goes (run 11b-1, the pairs of B3).
        var faded = session
        try faded.setFades(["A": Fades(fadeIn: 0, fadeOut: 480)!])
        var fadedJoin = faded
        try fadedJoin.trim("B", to: 96_000..<192_000)
        #expect(changedFrames(from: faded, to: fadedJoin)?.frames == 96_000..<192_000, "A keeps its fade-out handle")
        var shorter = joined
        try shorter.trim("B", to: 96_000..<180_000)
        #expect(changedFrames(from: joined, to: shorter)?.frames == 96_000..<192_000, "A stays joined")
    }

    /// C15a (decision 0038): a clip set is a drawn value, so a Command-click redraws the box of the
    /// clip that it adds or removes. Control: a compare that ignores the clip set gives no frames.
    @Test func aClipSelectionChangeRedrawsTheToggledBox() throws {
        let session = try Fixture.session()
        let a = Selection.clips(try #require(ClipSet(["A"])))
        let ab = Selection.clips(try #require(ClipSet(["A", "B"])))
        #expect(changedFrames(from: a, to: ab, in: session) == 144_000..<192_000, "the box of B")
        #expect(changedFrames(from: ab, to: a, in: session) == 144_000..<192_000)
        #expect(changedFrames(from: .none, to: a, in: session) == 48_000..<96_000, "the box of A")
        let range = Selection.range(Marks(inPoint: 0, outPoint: 24_000, tracks: ["t2"]))
        #expect(changedFrames(from: range, to: a, in: session) == 0..<96_000, "the band and the box")
        #expect(changedFrames(from: ab, to: ab, in: session).isEmpty)
    }

    /// Gain envelope C9 (decision 0020, the invariant): the envelope is a drawn value of the clip, so a
    /// point that comes, moves, or goes redraws the frames of that clip on its lane, and no other clip.
    /// Control: a compare that ignores the envelope gives no frames.
    @Test func anEnvelopeChangeMarksItsFrames() throws {
        let session = try Fixture.session()
        var added = session
        try added.setEnvelope([60_000: Gain(dB: -16)!, 80_000: Gain(dB: -16)!], clip: "A")
        var moved = added
        try moved.setEnvelope([60_000: Gain(dB: -16)!, 84_000: Gain(dB: -16)!], clip: "A")
        var removed = moved
        try removed.setEnvelope([:], clip: "A")

        for (old, new) in [(session, added), (added, moved), (moved, removed), (added, session)] {
            #expect(changedFrames(from: old, to: new)?.frames == 48_000..<96_000, "the frames of A")
            #expect(changedFrames(from: old, to: new)?.lanes == 0..<1, "the rows of t1 only")
        }
        var other = session
        try other.setEnvelope([150_000: Gain(dB: -6)!], clip: "B")
        #expect(changedFrames(from: session, to: other)?.frames == 144_000..<192_000, "the frames of B")
    }

    /// C53 guard (decision 0073): on fixture F a follow delete moves x and y by other deltas than the
    /// cut tracks, so no shift holds and the lanes draw in full.
    @Test func aFollowDeleteWithAnotherDeltaGivesNoShift() throws {
        var session = Session(sampleRate: 48_000)
        for (track, file) in [("host", "h"), ("bed", "b"), ("sfx", "s")] {
            try session.addTrack(TrackID(track), name: track, layout: .mono)
            try session.addFile(AudioFile(id: FileID(file), path: "\(file).wav", layout: .mono, length: 1_000_000))
        }
        try session.place(Clip(id: "h", file: "h", start: 0, offset: 0, length: 960_000), on: "host")
        try session.place(Clip(id: "bed", file: "b", start: 0, offset: 0, length: 960_000), on: "bed")
        try session.place(Clip(id: "w", file: "s", start: 192_000, offset: 0, length: 24_000), on: "sfx")
        try session.place(Clip(id: "x", file: "s", start: 264_000, offset: 100_000, length: 12_000), on: "sfx")
        try session.place(Clip(id: "y", file: "s", start: 360_000, offset: 200_000, length: 48_000), on: "sfx")
        try session.setFollowTrack(true, tracks: ["bed", "sfx"])
        var deleted = session
        try deleted.rippleDelete(240_000..<336_000, on: session.tracks.map(\.id), naming: [])
        #expect(deleted.clip("x")?.clip.start == 240_000 && deleted.clip("y")?.clip.start == 264_000)
        #expect(shiftedFrames(from: session, to: deleted) == nil)
    }

    /// Decisions 0022 and 0073: a lane whose clips do not change is still, whether it follows or
    /// not. A ripple trim of host over a bed clip that does not change gives a shift with the bed
    /// still. A move of the last clip of host is no ripple, so it gives no shift over either bed. A
    /// nudge of two host clips with a still clip between them, or with one that passes the still
    /// clip, is no ripple.
    @Test(arguments: [false, true])
    func anUnchangedLaneIsStill(follow: Bool) throws {
        var session = Session(sampleRate: 48_000)
        for (track, file) in [("host", "h"), ("bed", "b")] {
            try session.addTrack(TrackID(track), name: track, layout: .mono)
            try session.addFile(AudioFile(id: FileID(file), path: "\(file).wav", layout: .mono, length: 1_000_000))
        }
        try session.place(Clip(id: "h", file: "h", start: 100_000, offset: 0, length: 50_000), on: "host")
        try session.place(Clip(id: "h2", file: "h", start: 200_000, offset: 50_000, length: 50_000), on: "host")
        try session.place(Clip(id: "bed", file: "b", start: 0, offset: 0, length: 960_000), on: "bed")
        try session.setFollowTrack(follow, tracks: ["bed"])
        var trimmed = session
        try trimmed.rippleTrim("h", edge: .end, by: 25_000, on: ["host"], naming: [])
        var moved = session
        try moved.move("h2", to: "host", start: 225_000)

        let shift = shiftedFrames(from: session, to: trimmed)
        #expect(shift?.delta == 25_000 && shift?.still == [1], "\(String(describing: shift))")
        #expect(shiftedFrames(from: session, to: moved) == nil, "a move")

        try session.place(Clip(id: "h3", file: "h", start: 300_000, offset: 100_000, length: 50_000), on: "host")
        let nudges: [([ClipID], Frames)] = [(["h", "h3"], 4_800), (["h", "h3"], 160_000), (["h2", "h3"], -150_000)]
        for (clips, offset) in nudges {
            var nudged = session
            try nudged.nudge(clips, by: offset)
            #expect(shiftedFrames(from: session, to: nudged) == nil, "a nudge of \(clips) by \(offset)")
        }
    }

    /// C60 path 3 (U48): a Shuffle edge drag ripples its own track only. The other lanes keep their
    /// clips past the edit, so they are still, and the drag draws by a shift, not in full.
    @Test func aShuffleEdgeDragSkipsTheStillLanes() throws {
        var session = try Fixture.session()
        try session.place(Clip(id: "D", file: "fb", start: 200_000, offset: 0, length: 24_000), on: "t2")
        var trimmed = session
        try trimmed.rippleTrim("A", edge: .end, by: -9_600, on: ["t1"], naming: ["t1"])
        let shift = shiftedFrames(from: session, to: trimmed)
        #expect(shift?.delta == -9_600 && shift?.still == [1] && shift?.lines == [], "\(String(describing: shift))")
    }

    /// C60 path 2 (U49): a Shuffle move of A from t1 to a new mono t4 changes t1 (the close) and t4
    /// (the drop), and the marker between them moves on every lane. The parts name those two lanes
    /// and the marker lines, not t2 and t3, so the draw skips their rows.
    @Test func aCrossTrackShuffleChangesTwoLanes() throws {
        var session = try Fixture.session()
        try session.addTrack("t4", name: "T4", layout: .mono)
        try session.setMarker(Marker(id: "m", name: "m", position: 120_000, kind: .marker))
        var shuffled = session
        try shuffled.shuffle("A", to: "t4", start: 100_000)
        let changed = try #require(changedFrames(from: session, to: shuffled))
        #expect(changed.parts.filter { $0.lanes.count == 1 }.map(\.lanes) == [0..<1, 3..<4])
        #expect(changed.parts.filter { $0.lanes == 0..<4 }.map(\.frames.lowerBound).sorted() == [72_000, 120_000])
        #expect(changed.lanes == 0..<4, "the hull holds every part")
    }

    /// Decision 0037: a shift needs a lane whose clips before the moved clips change: the edit
    /// cuts, trims, inserts, or removes a clip there. A move alone gives the same sessions as a
    /// ripple in the gap before the moved clips, so both draw only the changed columns. A shift
    /// that also takes a move would draw the region copy to the end of the view.
    @Test func onlyAChangeBeforeTheMovedClipsGivesAShift() throws {
        let session = try Fixture.session()
        let excerpt = try session.excerpt(of: 48_000..<60_000, on: ["t2"])
        func delta(_ edit: (inout Session) throws -> Void) throws -> Frames? {
            var new = session
            try edit(&new)
            return shiftedFrames(from: session, to: new)?.delta
        }

        #expect(try delta { try $0.move("B", to: "t1", start: 150_000) } == nil, "a drag of the last clip")
        #expect(try delta { try $0.nudge(["A", "B", "C"], by: 4_800) } == nil, "a nudge of the clips of two lanes")
        #expect(try delta { try $0.rippleDelete(100_000..<120_000, on: ["t1"], naming: []) } == nil, "a gap delete")
        #expect(try delta { try $0.rippleInsert(9_600, at: 120_000, on: ["t1"], naming: []) } == nil, "a gap insert")
        #expect(try delta { _ = try $0.paste(excerpt, at: 100_000, on: ["t1"]) } == nil, "a paste over a gap")
        #expect(try delta { try $0.rippleDelete(60_000..<70_000, on: ["t1"], naming: []) } == -10_000, "a cut of A")
        #expect(try delta { try $0.rippleDelete(48_000..<96_000, on: ["t1"], naming: []) } == -48_000, "A goes")
        #expect(try delta { try $0.rippleInsert(9_600, at: 60_000, on: ["t1"], naming: []) } == 9_600, "a split of A")
        let pasted = try delta {
            try $0.rippleInsert(12_000, at: 120_000, on: ["t1"], naming: [])
            _ = try $0.paste(excerpt, at: 120_000, on: ["t1"])
        }
        #expect(pasted == 12_000, "a paste insert in a gap")
    }
}
