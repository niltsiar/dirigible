import DirigibleCore
import Testing

@testable import DirigibleTimeline

/// The Marks rules of decision 0017 (timeline-view criterion 12): one literal case per row of the
/// Marks table in the run design.
struct MarksTests {
    /// Tracks t1 to t`count`, with one clip of 480,000 frames at 0 on t1 when `clip` is true.
    static func session(tracks count: Int = 4, clip: Bool = true) throws -> Session {
        var session = Session(sampleRate: 48_000)
        for n in 1...count {
            try session.addTrack(TrackID("t\(n)"), name: "T\(n)", layout: .mono)
        }
        if clip {
            try session.addFile(AudioFile(id: "f1", path: "f1.wav", layout: .mono, length: 480_000))
            try session.place(Clip(id: "c1", file: "f1", start: 0, offset: 0, length: 480_000), on: "t1")
        }
        return session
    }

    @Test func aDragFromLaneOneToLaneThreeSelectsThreeTracks() throws {
        let session = try Self.session()

        let marks = Marks.drag(from: 9000, to: 1000, lanes: (0, 2), in: session)

        #expect(marks == Marks(inPoint: 1000, outPoint: 9000, tracks: ["t1", "t2", "t3"]))
        #expect(marks.selection(in: session)?.range == 1000..<9000)
        #expect(marks.selection(in: session)?.tracks == ["t1", "t2", "t3"])
        // Upward, and past the last lane.
        #expect(
            Marks.drag(from: 10, to: 20, lanes: (9, 2), in: session)
                == Marks(inPoint: 10, outPoint: 20, tracks: ["t3", "t4"]))
    }

    @Test func aShiftClickSelectsFromThePlayheadAndTheLaneJoins() {
        let marks = Marks(inPoint: 100, outPoint: 200, tracks: ["t1"])

        #expect(
            marks.extended(to: 500, lane: "t3", playhead: 900)
                == Marks(inPoint: 500, outPoint: 900, tracks: ["t1", "t3"]))
        #expect(
            Marks().extended(to: 900, lane: "t2", playhead: 500) == Marks(inPoint: 500, outPoint: 900, tracks: ["t2"]))
    }

    /// Mouse-edits criterion 10: a Shift-drag gives the hull of the two ranges and the union of the
    /// tracks. A point that is not set does not count.
    @Test func shiftDragExtendsTheRange() {
        let marks = Marks(inPoint: 1000, outPoint: 2000, tracks: ["t1"])
        let drag = Marks(inPoint: 5000, outPoint: 6000, tracks: ["t3"])

        #expect(marks.extended(by: drag) == Marks(inPoint: 1000, outPoint: 6000, tracks: ["t1", "t3"]))
        #expect(drag.extended(by: marks) == Marks(inPoint: 1000, outPoint: 6000, tracks: ["t1", "t3"]))
        #expect(Marks().extended(by: drag) == drag)
        #expect(
            Marks(outPoint: 500, tracks: ["t2"]).extended(by: drag)
                == Marks(inPoint: 500, outPoint: 6000, tracks: ["t2", "t3"]))
    }

    @Test func aCommandClickTogglesOneLaneAndKeepsTheRange() {
        let marks = Marks(inPoint: 100, outPoint: 200, tracks: ["t1", "t2"])

        #expect(marks.toggled("t3") == Marks(inPoint: 100, outPoint: 200, tracks: ["t1", "t2", "t3"]))
        #expect(marks.toggled("t2") == Marks(inPoint: 100, outPoint: 200, tracks: ["t1"]))
    }

    @Test func aCommandClickOnTheLastTrackEmptiesTheMarks() {
        #expect(Marks(inPoint: 100, outPoint: 200, tracks: ["t1"]).toggled("t1") == Marks())
    }

    @Test func iSetsInAndDropsAnOutAtOrBeforeIt() throws {
        let session = try Self.session()
        let marks = Marks(inPoint: 100, outPoint: 500, tracks: ["t2"])

        #expect(marks.settingIn(300, in: session) == Marks(inPoint: 300, outPoint: 500, tracks: ["t2"]))
        #expect(marks.settingIn(500, in: session) == Marks(inPoint: 500, outPoint: nil, tracks: ["t2"]))
        #expect(marks.settingIn(600, in: session) == Marks(inPoint: 600, outPoint: nil, tracks: ["t2"]))
    }

    @Test func oSetsOutAndDropsAnInAtOrAfterIt() throws {
        let session = try Self.session()
        let marks = Marks(inPoint: 300, outPoint: 900, tracks: ["t2"])

        #expect(marks.settingOut(500, in: session) == Marks(inPoint: 300, outPoint: 500, tracks: ["t2"]))
        #expect(marks.settingOut(300, in: session) == Marks(inPoint: nil, outPoint: 300, tracks: ["t2"]))
        #expect(marks.settingOut(200, in: session) == Marks(inPoint: nil, outPoint: 200, tracks: ["t2"]))
    }

    @Test func iAndOWithNoTracksTakeAllTracks() throws {
        let session = try Self.session(tracks: 3)

        #expect(Marks().settingIn(100, in: session) == Marks(inPoint: 100, tracks: ["t1", "t2", "t3"]))
        #expect(Marks().settingOut(100, in: session) == Marks(outPoint: 100, tracks: ["t1", "t2", "t3"]))
    }

    @Test func selectAllTakesEveryTrackFromZeroToTheEnd() throws {
        let session = try Self.session(tracks: 2)

        #expect(Marks.all(in: session) == Marks(inPoint: 0, outPoint: 480_000, tracks: ["t1", "t2"]))
    }

    @Test func selectAllOnAnEmptySessionGivesNoMarks() throws {
        #expect(Marks.all(in: try Self.session(tracks: 2, clip: false)) == Marks())
    }

    @Test func aRangeWithNoTracksIsNoSelection() throws {
        #expect(Marks(inPoint: 0, outPoint: 100).selection(in: try Self.session()) == nil)
        #expect(Marks(inPoint: 100, outPoint: 100, tracks: ["t1"]).selection(in: try Self.session()) == nil)
    }

    @Test func anUndoThatRemovesTheOnlyTrackGivesNoSelection() throws {
        var session = try Self.session()
        let marks = Marks(inPoint: 0, outPoint: 100, tracks: ["t4"])
        try session.removeTrack("t4")

        #expect(marks.selection(in: session) == nil)
    }

    @Test func anUndoThatRemovesOneOfTwoTracksKeepsTheOther() throws {
        var session = try Self.session()
        let marks = Marks(inPoint: 0, outPoint: 100, tracks: ["t3", "t4"])
        try session.removeTrack("t4")

        #expect(marks.selection(in: session)?.range == 0..<100)
        #expect(marks.selection(in: session)?.tracks == ["t3"])
    }

    /// Edit-commands criterion 16: the first selected track in session order and the tracks under
    /// it, one per lane; with no selected track in the session, the source tracks. Too few tracks
    /// under it give a short list, so Core refuses with `trackCount` (code gate 1 item 4). Controls:
    /// always the source tracks fails the first row; a nil for a short list fails the t4 row.
    @Test func pasteTracks() throws {
        var session = try Self.session()
        let two = try session.excerpt(of: 0..<100, on: ["t1", "t2"])
        #expect(Marks(tracks: ["t2"]).pasteTracks(for: two, in: session) == ["t2", "t3"])
        #expect(Marks(tracks: ["t3", "t1"]).pasteTracks(for: two, in: session) == ["t1", "t2"])
        #expect(Marks(tracks: ["t4"]).pasteTracks(for: two, in: session) == ["t4"])
        #expect(Marks().pasteTracks(for: two, in: session) == ["t1", "t2"])
        #expect(Marks(tracks: ["t9"]).pasteTracks(for: two, in: session) == ["t1", "t2"])
        try session.removeTrack("t2")
        #expect(Marks().pasteTracks(for: two, in: session) == nil)
        #expect(Marks(tracks: ["t3"]).pasteTracks(for: two, in: session) == ["t3", "t4"])
    }

    /// Edit-commands criterion 17: a range splits at in and out on the selected tracks; else the
    /// playhead on the selected tracks, or on every track. Controls: the first selected track only
    /// fails the first row; every track also with a selection fails it too.
    @Test func splitPoints() throws {
        let session = try Self.session(tracks: 3)
        let rows: [(Marks, [Frames], [TrackID])] = [
            (Marks(inPoint: 100, outPoint: 200, tracks: ["t3", "t1"]), [100, 200], ["t1", "t3"]),
            (Marks(tracks: ["t2"]), [50], ["t2"]),
            (Marks(inPoint: 100, tracks: ["t2"]), [50], ["t2"]),
            (Marks(), [50], ["t1", "t2", "t3"]),
            (Marks(tracks: ["t9"]), [50], ["t1", "t2", "t3"]),
        ]
        for (marks, frames, tracks) in rows {
            let points = marks.splitPoints(playhead: 50, in: session)
            #expect(points.frames == frames && points.tracks == tracks, "\(marks)")
        }
    }

    /// Edit-commands criterion 18: the clips fully inside the range on the selected tracks; a left
    /// offset stops at frame 0; the Marks move with the clips. Controls: the overlapping clips
    /// fail the b row; no clamp fails the left rows.
    /// Run 8b criterion 12b: each whole clip that the selection touches on its tracks. The range is
    /// half-open: a clip that starts at the out point is not in the set.
    @Test func clipsToLevelTakesEachTouchedClip() throws {
        var session = try Self.session()
        try session.place(Clip(id: "c2", file: "f1", start: 480_000, offset: 0, length: 480_000), on: "t1")
        try session.place(Clip(id: "c3", file: "f1", start: 0, offset: 0, length: 480_000), on: "t2")

        #expect(Marks(inPoint: 1000, outPoint: 2000, tracks: ["t1"]).clipsToLevel(in: session) == ["c1"])
        #expect(
            Marks(inPoint: 1000, outPoint: 480_000, tracks: ["t1", "t2"]).clipsToLevel(in: session) == ["c1", "c3"])
        #expect(Marks(inPoint: 479_999, outPoint: 480_001, tracks: ["t1"]).clipsToLevel(in: session) == ["c1", "c2"])
        #expect(Marks(inPoint: 0, outPoint: 10, tracks: ["t3"]).clipsToLevel(in: session) == [])
        #expect(Marks(tracks: ["t1"]).clipsToLevel(in: session) == nil)
        #expect(Marks(inPoint: 0, outPoint: 10).clipsToLevel(in: session) == nil)
    }

    @Test func nudge() throws {
        var session = try Self.session(tracks: 2, clip: false)
        try session.addFile(AudioFile(id: "f1", path: "f1.wav", layout: .mono, length: 480_000))
        for (id, start, track) in [("a", 1000, "t1"), ("b", 3000, "t1"), ("c", 1500, "t2")] {
            try session.place(
                Clip(id: ClipID(id), file: "f1", start: Frames(start), offset: 0, length: 1000), on: TrackID(track))
        }
        let rows: [(Marks, Frames, [ClipID], Frames, Marks)] = [
            (
                Marks(inPoint: 1000, outPoint: 4000, tracks: ["t1"]), 480, ["a", "b"], 480,
                Marks(inPoint: 1480, outPoint: 4480, tracks: ["t1"])
            ),
            (
                Marks(inPoint: 1000, outPoint: 3500, tracks: ["t2", "t1"]), 480, ["a", "c"], 480,
                Marks(inPoint: 1480, outPoint: 3980, tracks: ["t1", "t2"])
            ),
            (
                Marks(inPoint: 1001, outPoint: 4000, tracks: ["t1"]), 480, ["b"], 480,
                Marks(inPoint: 1481, outPoint: 4480, tracks: ["t1"])
            ),
            (
                Marks(inPoint: 500, outPoint: 4000, tracks: ["t1"]), -480, ["a", "b"], -480,
                Marks(inPoint: 20, outPoint: 3520, tracks: ["t1"])
            ),
            (
                Marks(inPoint: 900, outPoint: 2000, tracks: ["t1"]), -1200, ["a"], -1000,
                Marks(inPoint: 0, outPoint: 1000, tracks: ["t1"])
            ),
        ]
        for (marks, step, clips, offset, moved) in rows {
            let move = try #require(marks.nudge(by: step, in: session), "\(marks)")
            #expect(move.clips == clips && move.offset == offset && move.marks == moved, "\(marks)")
        }
        #expect(Marks(inPoint: 1100, outPoint: 3900, tracks: ["t1"]).nudge(by: 480, in: session) == nil)
        #expect(Marks(inPoint: 1000, outPoint: 4000).nudge(by: 480, in: session) == nil)
        try session.place(Clip(id: "z", file: "f1", start: 0, offset: 0, length: 500), on: "t1")
        #expect(Marks(inPoint: 0, outPoint: 4000, tracks: ["t1"]).nudge(by: -480, in: session) == nil)
    }

    // MARK: Command-F (decision 0035)

    /// Clip A at 48,000 (1 s by default) on t1, clip B (1 s) at `b` on t1, and clip C at 0 on t2.
    static func fadeSession(a length: Frames = 48_000, b: Frames? = nil, aFades: Fades = .zero) throws -> Session {
        var session = try session(tracks: 2, clip: false)
        try session.addFile(AudioFile(id: "f1", path: "f1.wav", layout: .mono, length: 480_000))
        try session.place(Clip(id: "A", file: "f1", start: 48_000, offset: 0, length: length, fades: aFades), on: "t1")
        if let b { try session.place(Clip(id: "B", file: "f1", start: b, offset: 0, length: 48_000), on: "t1") }
        try session.place(Clip(id: "C", file: "f1", start: 0, offset: 0, length: 192_000), on: "t2")
        return session
    }

    func fades(_ range: Range<Frames>, _ session: Session, tracks: Set<TrackID> = ["t1"]) -> [ClipID: Fades]? {
        Marks(inPoint: range.lowerBound, outPoint: range.upperBound, tracks: tracks).fades(in: session)
    }

    /// C15: a range that holds the clip start fades in to the out point.
    @Test func fadeAtAClipStart() throws {
        #expect(fades(40_000..<52_800, try Self.fadeSession()) == ["A": Fades(fadeIn: 4_800, fadeOut: 0)!])
    }

    /// C16: a range that holds the clip end fades out from the in point.
    @Test func fadeAtAClipEnd() throws {
        #expect(fades(91_200..<100_000, try Self.fadeSession()) == ["A": Fades(fadeIn: 0, fadeOut: 4_800)!])
    }

    /// C17: the whole clip gets min(0.5 s, length / 2) at each end.
    @Test func fadeOfAWholeClip() throws {
        #expect(fades(48_000..<96_000, try Self.fadeSession()) == ["A": Fades(fadeIn: 24_000, fadeOut: 24_000)!])
        #expect(
            fades(48_000..<76_800, try Self.fadeSession(a: 28_800))
                == ["A": Fades(fadeIn: 14_400, fadeOut: 14_400)!], "0.6 s")
        #expect(
            fades(48_000..<105_600, try Self.fadeSession(a: 57_600))
                == ["A": Fades(fadeIn: 24_000, fadeOut: 24_000)!], "1.2 s")
    }

    /// C18: a range inside the clip holds no edge.
    @Test func fadeInsideAClipDoesNothing() throws {
        #expect(fades(60_000..<70_000, try Self.fadeSession()) == nil)
    }

    /// C19: an edge at a butt join gets no fade; a 1-frame gap is not a join.
    @Test func fadeAtAButtJoinDoesNothing() throws {
        #expect(fades(90_000..<100_000, try Self.fadeSession(b: 96_000)) == nil, "a butt join")
        #expect(
            fades(90_000..<100_000, try Self.fadeSession(b: 96_001))
                == ["A": Fades(fadeIn: 0, fadeOut: 6_000)!, "B": Fades(fadeIn: 3_999, fadeOut: 0)!], "a 1-frame gap")
    }

    /// Crossfades F2: Command-F gives no fade at a crossfade edge, and the fade of the free edge
    /// fits the room beside the crossfade half (1,000 - 600).
    @Test func fadeSkipsACrossfadeEdge() throws {
        var session = try Self.fadeSession(a: 1_000)
        try session.place(Clip(id: "B", file: "f1", start: 49_000, offset: 10_000, length: 48_000), on: "t1")
        try session.setCrossfades(["A": 1_200])
        #expect(
            fades(40_000..<100_000, session)
                == ["A": Fades(fadeIn: 400, fadeOut: 0)!, "B": Fades(fadeIn: 0, fadeOut: 24_000)!])
    }

    /// C20: no in point or no selected track that exists gives nil; a clip on a track that is not
    /// selected does not change.
    @Test func fadeNeedsASelection() throws {
        let session = try Self.fadeSession()
        #expect(Marks(outPoint: 96_000, tracks: ["t1"]).fades(in: session) == nil, "no in point")
        #expect(fades(48_000..<96_000, session, tracks: ["t9"]) == nil, "no selected track that exists")
        #expect(fades(48_000..<96_000, session).map { Set($0.keys) } == ["A"], "C on t2 does not change")
    }

    /// C21: the new fade wins, and the other fade yields.
    @Test func theNewFadeWins() throws {
        let session = try Self.fadeSession(aFades: Fades(fadeIn: 0, fadeOut: 40_000)!)
        #expect(fades(40_000..<62_400, session) == ["A": Fades(fadeIn: 14_400, fadeOut: 33_600)!])
    }
}
