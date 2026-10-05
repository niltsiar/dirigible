import DirigibleCore
import Testing

@testable import DirigibleTimeline

/// Command-F at a butt join (decision 0036, criteria C1 to C9 of run 11c-2). Clip A (1 s by
/// default, file fa, offset 0) ends at the join J = 96,000, and clip B (1 s, file fb) starts at J
/// with 48,000 frames of handle by default. A has 96,000 - its length frames of handle after it.
/// Clip C is on t2. 48 kHz.
struct MarksCrossfadeTests {
    static func session(
        a length: Frames = 48_000, bOffset: Frames = 48_000, bFile: FileID = "fb", aFades: Fades = .zero
    ) throws -> Session {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "fa", path: "fa.wav", layout: .mono, length: 96_000))
        try session.addFile(AudioFile(id: "fb", path: "fb.wav", layout: .mono, length: 144_000))
        try session.addTrack("t1", name: "T1", layout: .mono)
        try session.addTrack("t2", name: "T2", layout: .mono)
        try session.place(
            Clip(id: "A", file: "fa", start: 96_000 - length, offset: 0, length: length, fades: aFades), on: "t1")
        try session.place(Clip(id: "B", file: bFile, start: 96_000, offset: bOffset, length: 48_000), on: "t1")
        try session.place(Clip(id: "C", file: "fa", start: 0, offset: 0, length: 96_000), on: "t2")
        return session
    }

    func marks(_ range: Range<Frames>, tracks: Set<TrackID> = ["t1"]) -> Marks {
        Marks(inPoint: range.lowerBound, outPoint: range.upperBound, tracks: tracks)
    }

    func crossfades(_ id: ClipID, _ session: Session?) -> Crossfades? { session?.clip(id)?.clip.crossfades }
    func fades(_ id: ClipID, _ session: Session?) -> Fades? { session?.clip(id)?.clip.fades }

    /// C1: a range across J gives 2 x min(J - in, out - J), centered on J. Fail value: 3,000.
    @Test func aRangeAcrossAJoinGivesTwiceTheNearerSide() throws {
        let session = try Self.session()
        let marks = marks(95_000..<97_500)

        #expect(marks.crossfades(in: session) == ["A": 2_000])
        let result = try marks.faded(session)
        #expect(crossfades("A", result) == Crossfades(start: 0, end: 2_000))
        #expect(crossfades("B", result) == Crossfades(start: 2_000, end: 0))
        #expect(fades("A", result) == .zero && fades("B", result) == .zero, "no free edge in the range")
    }

    /// C2: a range that holds both clips whole gives 20 ms at J, and the 0035 fades at the free
    /// edges, fitted to the room beside the crossfade half.
    @Test func bothClipsWholeGiveTwentyMilliseconds() throws {
        let result = try marks(0..<200_000).faded(try Self.session())
        #expect(crossfades("A", result) == Crossfades(start: 0, end: 960))
        #expect(crossfades("B", result) == Crossfades(start: 960, end: 0))
        #expect(fades("A", result) == Fades(fadeIn: 24_000, fadeOut: 0))
        #expect(fades("B", result) == Fades(fadeIn: 0, fadeOut: 24_000))
        #expect(crossfades("C", result) == .zero && fades("C", result) == .zero, "t2 is not selected")

        // A of 900 frames: the standard fade-in is 450, and the room beside the half (480) is 420.
        let short = try marks(0..<200_000).faded(try Self.session(a: 900))
        #expect(crossfades("A", short) == Crossfades(start: 0, end: 960))
        #expect(fades("A", short) == Fades(fadeIn: 420, fadeOut: 0))
    }

    /// The lane-indexed edits of Command-F give the same session as the edits by clip ID, for
    /// ranges across, inside, and around the joins and the gap of two tracks.
    @Test func theLaneEditsMatchTheEditsByID() throws {
        var session = try Self.session(a: 900, aFades: Fades(fadeIn: 300, fadeOut: 300)!)
        try session.place(Clip(id: "D", file: "fb", start: 144_000, offset: 100_000, length: 24_000), on: "t1")
        try session.place(Clip(id: "E", file: "fa", start: 200_000, offset: 0, length: 48_000), on: "t1")
        try session.place(Clip(id: "F", file: "fb", start: 96_000, offset: 0, length: 48_000), on: "t2")
        var changed = 0
        for range in [0..<300_000, 95_000..<97_500, 50_000..<150_000, 143_000..<210_000] as [Range<Frames>] {
            for tracks in [["t1"], ["t1", "t2"]] as [Set<TrackID>] {
                let marks = marks(range, tracks: tracks)
                var byID = session
                if let lengths = marks.crossfades(in: session) { try byID.setCrossfades(lengths) }
                if let fades = marks.fades(in: byID) { try byID.setFades(fades) }
                var byLane = session
                if let joins = marks.crossfadeJoins(in: session) { try byLane.setCrossfades(lanes: joins) }
                if let fades = marks.fadeEdits(in: byLane) { try byLane.setFades(lanes: fades) }
                #expect(byLane == byID, "\(range) \(tracks)")
                if byID != session { changed += 1 }
            }
        }
        #expect(changed == 8, "each case changes the session")
    }

    /// C3: a range that ends or starts at J makes no crossfade, and the join edge gets no fade.
    @Test func aRangeThatTouchesTheJoinMakesNoCrossfade() throws {
        let session = try Self.session()
        for range in [90_000..<96_000, 96_000..<100_000] as [Range<Frames>] {
            #expect(marks(range).crossfades(in: session) == nil, "\(range)")
            #expect(try marks(range).faded(session) == nil, "\(range)")
        }
    }

    /// C4 and C5: a range inside one clip, no in point, or no selected track that exists: nil.
    @Test func noJoinOrNoSelectionGivesNil() throws {
        let session = try Self.session()
        #expect(try marks(60_000..<70_000).faded(session) == nil, "inside A")
        #expect(try Marks(outPoint: 97_500, tracks: ["t1"]).faded(session) == nil, "no in point")
        #expect(try marks(95_000..<97_500, tracks: ["t9"]).faded(session) == nil, "no selected track")
    }

    /// C6: the length clamps to 2 x the shorter handle. Fail value: 602. B with no handle gets no
    /// crossfade.
    @Test func theLengthClampsToTheHandle() throws {
        let short = try marks(95_000..<97_500).faded(try Self.session(bOffset: 300))
        #expect(crossfades("A", short) == Crossfades(start: 0, end: 600))
        #expect(try marks(95_000..<97_500).faded(try Self.session(bOffset: 0)) == nil, "no handle before B")
    }

    /// C7: a seamless join (B plays on in A's file) gets no crossfade.
    @Test func aSeamlessJoinGetsNoCrossfade() throws {
        let session = try Self.session(bOffset: 48_000, bFile: "fa")
        #expect(session.clip("B")?.clip.isSeamless(with: session.clip("A")!.clip) == false)
        #expect(session.clip("A")?.clip.isSeamless(with: session.clip("B")!.clip) == true)
        #expect(try marks(95_000..<97_500).faded(session) == nil)
    }

    /// C8: the crossfade replaces a fade-out of A at J.
    @Test func theCrossfadeReplacesAFadeAtTheJoin() throws {
        let session = try Self.session(aFades: Fades(fadeIn: 0, fadeOut: 4_800)!)
        let result = try marks(95_000..<97_500).faded(session)
        #expect(crossfades("A", result) == Crossfades(start: 0, end: 2_000))
        #expect(fades("A", result) == .zero)
    }

    /// C9: the same length again changes nothing; another length changes it.
    @Test func theSameLengthAgainChangesNothing() throws {
        var session = try Self.session()
        try session.setCrossfades(["A": 960])
        #expect(try marks(95_520..<96_480).faded(session) == nil, "960 again")
        #expect(crossfades("A", try marks(95_000..<97_500).faded(session)) == Crossfades(start: 0, end: 2_000))
    }

    /// A short middle clip between two joins: the first join takes the room of the clip, and the
    /// second join gets what is left (here 0), so the two halves never pass the length of B.
    @Test func twoJoinsShareTheRoomOfAShortClip() throws {
        var session = try Self.session()
        try session.trim("B", to: 96_000..<96_600)
        try session.place(Clip(id: "D", file: "fa", start: 96_600, offset: 50_000, length: 40_000), on: "t1")

        #expect(marks(50_000..<130_000).crossfades(in: session) == ["A": 1_200])
        let result = try marks(50_000..<130_000).faded(session)
        #expect(crossfades("B", result) == Crossfades(start: 1_200, end: 0))
    }
}
