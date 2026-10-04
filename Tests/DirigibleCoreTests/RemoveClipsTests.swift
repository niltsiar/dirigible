import Testing

@testable import DirigibleCore

/// Multi-clip-selection criterion C11a (Core): `removeClips` removes the clips and leaves gaps.
/// Track "a" has "A" at 0..<10 000, "B" at 10 000..<20 000, and "N" at 20 000..<40 000; track
/// "b" has "W" at 0..<50 000.
struct RemoveClipsTests {
    var session: Session

    init() throws {
        session = try editFixture()
        try session.addFile(AudioFile(id: "h", path: "h.wav", layout: .mono, length: 480_000))
        try session.place(Clip(id: "A", file: "f", start: 0, offset: 0, length: 10_000), on: "a")
        try session.place(Clip(id: "B", file: "h", start: 10_000, offset: 10_000, length: 10_000), on: "a")
        try session.place(Clip(id: "N", file: "f", start: 20_000, offset: 20_000, length: 20_000), on: "a")
        try session.place(Clip(id: "W", file: "f", start: 0, offset: 0, length: 50_000), on: "b")
    }

    @Test mutating func removeClipsLeavesGapsAndKeepsOtherClips() throws {
        try session.setCrossfades(["A": 960])
        try session.removeClips(["B", "W"])
        #expect(
            session.track("a").map { Array($0.clips) } == [
                Clip(id: "A", file: "f", start: 0, offset: 0, length: 10_000),
                Clip(id: "N", file: "f", start: 20_000, offset: 20_000, length: 20_000),
            ], "the gap stays, and the broken join drops the crossfade of A")
        #expect(session.track("b")?.clips.isEmpty == true)
        #expect((try? session.checkedData()) != nil, "the session saves")
    }

    @Test mutating func removeClipsWithAnUnknownIDThrowsAndChangesNothing() throws {
        let before = session
        #expect(throws: SessionError.unknownClip("x")) { try session.removeClips(["A", "x"]) }
        #expect(session == before)
    }

    /// Code gate 1 item 2: a Delete of a clip set after Select All (6 tracks of 2,000 clips) checks
    /// the IDs in one pass. Control: a check of each ID with `clip(_:)` scans every lane per ID,
    /// about 72 million compares, which takes seconds even in an optimized build.
    @Test func removeClipsOfTwelveThousandClipsIsOnePass() throws {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f", path: "f.wav", layout: .mono, length: 2_000_000))
        let tracks = (1...6).map { TrackID("t\($0)") }
        for track in tracks {
            try session.addTrack(track, name: track.rawValue, layout: .mono)
            try session.place(
                Clip(id: ClipID("c-\(track)"), file: "f", start: 0, offset: 0, length: 2_000_000), on: track)
        }
        _ = try session.splitClips(at: (1..<2000).map { Frames($0 * 1_000) }, on: tracks)
        let ids = session.tracks.flatMap { $0.clips.map(\.id) }
        try #require(ids.count == 12_000)
        let start = ContinuousClock.now
        try session.removeClips(ids)
        let elapsed = ContinuousClock.now - start
        #expect(session.tracks.allSatisfy { $0.clips.isEmpty })
        #expect(elapsed < .milliseconds(1_500), "removeClips of 12,000 clips took \(elapsed)")
    }
}
