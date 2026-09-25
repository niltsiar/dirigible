import DirigibleCore
import Testing

@testable import DirigibleApp

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
}
