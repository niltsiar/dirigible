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
        try cleared.clear(72_000..<96_000, on: "t1")
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
}
