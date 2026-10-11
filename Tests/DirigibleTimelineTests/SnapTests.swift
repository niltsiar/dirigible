import DirigibleCore
import Testing

@testable import DirigibleTimeline

/// The snap search of the snap run (criterion C3): 480 frames per point (`Fixture.geometry`), so
/// the reach of 6 pt is 2,880 frames. Clip A is on t1 at 48,000 ..< 96,000; the tests put the
/// other targets near frame 96,000.
struct SnapTests {
    static let point = Frames(480)

    /// A session with A on t1, C on t2, and a clip T on t1 at 120,000 of `width` points.
    static func session(width: Double) throws -> Session {
        var session = try Fixture.session(withB: false)
        let length = Frames(Int(width * 480))
        try session.place(Clip(id: "T", file: "fb", start: 120_000, offset: 0, length: length), on: "t1")
        return session
    }

    @Test func aClipUnder12PointsGivesNoTarget() throws {
        let edge = Frames(120_000) - Self.point
        let narrow = Snap(try Self.session(width: 11), excluding: ["A"], geometry: Fixture.geometry)
        #expect(narrow.shift([edge], playhead: 1_000_000) == nil)
        let wide = Snap(try Self.session(width: 12), excluding: ["A"], geometry: Fixture.geometry)
        let snapped = try #require(wide.shift([edge], playhead: 1_000_000))
        #expect(snapped.by == Self.point && snapped.target == 120_000)
    }

    @Test func theReachIs6Points() throws {
        let snap = Snap(try Fixture.session(withB: false), geometry: Fixture.geometry)
        // The end of A at 96,000: 5 pt away snaps, 7 pt away does not.
        let near = Frames(96_000) + Frames(5 * 480)
        #expect(snap.shift([near], playhead: 1_000_000).map(\.target) == 96_000)
        #expect(snap.shift([Frames(96_000) + Frames(7 * 480)], playhead: 1_000_000) == nil)
        // The clip C on t2 also has its end at 96,000; a start edge 5 pt before 48,000 snaps too.
        #expect(snap.shift([Frames(48_000) - Frames(5 * 480)], playhead: 1_000_000).map(\.target) == 48_000)
    }

    @Test func theNearerEdgeWins() throws {
        let snap = Snap(try Fixture.session(withB: false), geometry: Fixture.geometry)
        // Edge 1 is 4 pt from 96,000; edge 2 is 2 pt from 48,000.
        let shifted = try #require(
            snap.shift([Frames(96_000) + Frames(4 * 480), Frames(48_000) + Frames(2 * 480)], playhead: 1_000_000))
        #expect(shifted.target == 48_000 && shifted.by == .zero - Frames(2 * 480))
    }

    @Test func thePlayheadThenAMarkerThenAClipEdgeAtATie() throws {
        var session = try Fixture.session(withB: false)
        let edge = Frames(96_000) + Frames(2 * 480)
        // The end of A is 2 pt before the edge; a marker 2 pt after it.
        try session.setMarker(Marker(id: "m", name: "M", position: edge + Frames(2 * 480), kind: .chapter))
        let snap = Snap(session, geometry: Fixture.geometry)
        #expect(snap.shift([edge], playhead: 1_000_000)?.target == edge + Frames(2 * 480))
        // The playhead at the clip edge wins over the marker at the same distance.
        #expect(snap.shift([edge], playhead: 96_000)?.target == 96_000)
    }

    @Test func anExcludedClipGivesNoTarget() throws {
        let snap = Snap(try Fixture.session(withB: false), excluding: ["A", "C"], geometry: Fixture.geometry)
        #expect(snap.shift([Frames(96_000) + Self.point], playhead: 1_000_000) == nil)
        // The playhead stays a target with every clip excluded.
        #expect(snap.shift([Frames(96_000) + Self.point], playhead: 96_000)?.target == 96_000)
    }

    /// Property on fixed pseudo-random clips: a found target is in reach, and no target in reach is
    /// nearer (an oracle that scans every edge). The values come from a multiplicative sequence, so
    /// each run has the same cases.
    @Test func theTargetIsTheNearestOfAScan() throws {
        var value: UInt64 = 7
        func next() -> UInt64 {
            value = value &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return value >> 33
        }
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f", path: "f.wav", layout: .mono, length: 4_800_000))
        try session.addTrack("t1", name: "T1", layout: .mono)
        try session.addTrack("t2", name: "T2", layout: .mono)
        var start = 0
        for n in 0..<60 {
            start += Int(next() % 20_000)
            let length = 2_000 + Int(next() % 20_000)
            try session.place(
                Clip(id: ClipID("c\(n)"), file: "f", start: Frames(start), offset: 0, length: Frames(length)),
                on: n % 2 == 0 ? "t1" : "t2")
            start += length
        }
        let snap = Snap(session, geometry: Fixture.geometry)
        let wide = session.tracks.flatMap(\.clips).filter { Double($0.length.count) / 480 >= 12 }
        let edges = wide.flatMap { [$0.start, $0.end] }
        for _ in 0..<200 {
            let edge = Frames(Int(next() % UInt64(start)))
            let best = edges.map { abs(($0 - edge).count) }.min() ?? .max
            let found = snap.shift([edge], playhead: Frames.limit)
            if best <= 2_880 {
                #expect(found.map { abs(($0.target - edge).count) } == best)
            } else {
                #expect(found == nil)
            }
        }
    }
}
