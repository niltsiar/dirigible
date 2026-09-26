import DirigibleCore
import Testing

@testable import DirigibleTimeline

/// Mouse-edits criterion 6, the pure part: the frames that a clip edge can reach, at the zoom of
/// the small fixture (1 pt is 480 frames).
struct TrimLimitsTests {
    let minimum = Fixture.geometry.trimMinimum

    /// The limits with the pool length of the file of `clip`, or with `fileLength` (a WAV on disk
    /// that is shorter than its pool entry).
    func limits(_ clip: Clip, _ edge: Edge, _ session: Session, fileLength: Frames? = nil) throws
        -> ClosedRange<Frames>
    {
        let (_, track) = try #require(session.clip(clip.id))
        let lane = try #require(session.track(track)).clips
        let length = try fileLength ?? #require(session.files[clip.file]).length
        return trimLimits(clip, edge: edge, in: lane, fileLength: length, minimum: minimum)
    }

    @Test func trimLimitsStopAtTheNeighborsTheFileAndTheMinimum() throws {
        let session = try Fixture.session()
        #expect(minimum == 480)

        // A starts at frame 0 of fa, so its start cannot go left; it stops 1 pt before its end.
        #expect(try limits(Fixture.a, .start, session) == 48_000...95_520)
        // The end of A stops at the start of B, and 1 pt after its start.
        #expect(try limits(Fixture.a, .end, session) == 48_480...144_000)
        // With no B, the end of A stops at the end of fa.
        #expect(try limits(Fixture.a, .end, Fixture.session(withB: false)) == 48_480...192_000)
        // The start of B stops at the end of A (B's file frame 0 is also at 96,000).
        #expect(try limits(Fixture.b, .start, session) == 96_000...191_520)
        #expect(try limits(Fixture.b, .end, session) == 144_480...240_000)
        // G starts at frame 72,000 of fa, so fa starts at 48,000, before the end of C: C stops it.
        var withG = session
        let g = Clip(id: "G", file: "fa", start: 120_000, offset: 72_000, length: 24_000)
        try withG.place(g, on: "t2")
        #expect(try limits(g, .start, withG) == 96_000...143_520)
    }

    /// A clip shorter than the minimum, and a clip that passes the end of its WAV (a WAV shorter
    /// than its pool entry): the range still holds the edge where it is.
    @Test func trimLimitsAlwaysHoldTheCurrentEdge() throws {
        var session = try Fixture.session()
        let tiny = Clip(id: "T", file: "fa", start: 400_000, offset: 0, length: 100)
        let long = Clip(id: "L", file: "fa", start: 500_000, offset: 96_000, length: 48_000)
        try session.place(tiny, on: "t2")
        try session.place(long, on: "t2")

        #expect(try limits(tiny, .start, session) == 400_000...400_000)
        #expect(try limits(tiny, .end, session) == 400_100...500_000, "up to the start of L")
        // A WAV of 140,000 frames ends at 544,000, before the end of L at 548,000.
        #expect(try limits(long, .end, session, fileLength: 140_000) == 500_480...548_000)
    }
}
