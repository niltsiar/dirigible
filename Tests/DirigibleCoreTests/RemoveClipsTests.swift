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
}
