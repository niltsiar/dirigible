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

    /// Edit-commands criterion 7. A marker and a chapter at 10 000, a marker at 30 000.
    /// Controls: "after" that includes the frame gives 10 000 at 10 000; "after" that returns the
    /// farthest gives 30 000 at 0.
    @Test mutating func markerPositionIsStrictlyAfterAndBefore() throws {
        #expect(session.markerPosition(after: 0) == nil && session.markerPosition(before: 100) == nil)
        try session.setMarker(Marker(id: "m1", name: "One", position: 10_000, kind: .marker))
        try session.setMarker(Marker(id: "c1", name: "Two", position: 10_000, kind: .chapter))
        try session.setMarker(Marker(id: "m2", name: "Three", position: 30_000, kind: .marker))
        #expect(session.markerPosition(after: 0) == 10_000)
        #expect(session.markerPosition(after: 10_000) == 30_000)
        #expect(session.markerPosition(after: 30_000) == nil)
        #expect(session.markerPosition(before: 30_000) == 10_000)
        #expect(session.markerPosition(before: 10_000) == nil)
        #expect(session.markerPosition(before: 50_000) == 30_000)
    }
}
