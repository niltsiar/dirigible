import DirigibleCore
import Testing

/// The clip edges and the clip at a frame (timeline-playback criteria 17 and 21), with literal
/// frames. Track "t1" has clips at 0..<10 000 and 30 000..<40 000; track "t2" has one at
/// 5 000..<20 000.
struct TimelineEdgeTests {
    var session: Session

    init() throws {
        session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f1", path: "a.wav", layout: .mono, length: 100_000))
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.addTrack("t2", name: "Guest", layout: .mono)
        try session.place(Clip(id: "c1", file: "f1", start: 0, offset: 0, length: 10_000), on: "t1")
        try session.place(Clip(id: "c2", file: "f1", start: 30_000, offset: 0, length: 10_000), on: "t1")
        try session.place(Clip(id: "c3", file: "f1", start: 5_000, offset: 0, length: 15_000), on: "t2")
    }

    /// Control: no edge after the last edge, and no edge before 0.
    @Test(
        arguments: [
            (Frames(0), Frames(5_000), nil),
            (1, 5_000, 0),
            (5_000, 10_000, 0),
            (12_000, 20_000, 10_000),
            (20_000, 30_000, 10_000),
            (35_000, 40_000, 30_000),
            (40_000, nil, 30_000),
            (50_000, nil, 40_000),
        ] as [(Frames, Frames?, Frames?)])
    func edgesOverAllTracks(frame: Frames, after: Frames?, before: Frames?) {
        #expect(session.edge(after: frame) == after)
        #expect(session.edge(before: frame) == before)
    }

    @Test func anEmptySessionHasNoEdgeAndEndsAtZero() {
        let empty = Session(sampleRate: 48_000)
        #expect(empty.edge(after: 0) == nil && empty.edge(before: 100) == nil && empty.end == 0)
        #expect(session.end == 40_000)
    }

    /// Controls: a clip end is not in the clip, and a clip on a track that is not armed does not
    /// count.
    @Test(
        arguments: [
            (Frames(0), ["t1"] as [TrackID], true),
            (9_999, ["t1"], true),
            (10_000, ["t1"], false),
            (15_000, ["t1"], false),
            (15_000, ["t2"], true),
            (15_000, ["t1", "t2"], true),
            (20_000, ["t2"], false),
            (39_999, ["t2"], false),
            (39_999, ["t1"], true),
            (0, [], false),
        ] as [(Frames, [TrackID], Bool)])
    func hasClipAtTheFrameOnArmedTracks(frame: Frames, armed: [TrackID], expected: Bool) {
        #expect(session.hasClip(at: frame, on: armed) == expected)
    }
}
