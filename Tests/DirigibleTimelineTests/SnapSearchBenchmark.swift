import DirigibleCore
import Foundation
import Testing

@testable import DirigibleTimeline

/// Snap run S1, a proxy of criterion C12: the snap search of one drag event (two edges) at 2 h
/// (6 tracks of 2,000 clips, 200 markers) takes 2 ms p95 or less in an optimized build, at fit zoom
/// and at the zoom of 60 pt boxes (`make bench FILTER=SnapSearchBenchmark`). The sum of the event:
/// a move of 3.6 ms (0018 P4) and a draw of 4.6 ms p95 (0017), so 2 ms keeps it under 16 ms. The
/// search set-up at the drag start has the same budget. `make test-slow` runs it unoptimized with a
/// budget of 20 ms, a proxy only.
struct SnapSearchBenchmark {
    #if DEBUG
        static let budget = Duration.milliseconds(20)
    #else
        static let budget = Duration.milliseconds(2)
    #endif
    static let frames = 345_600_000

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aSnapSearchFitsItsPartOfTheFrame() throws {
        var session = Session(sampleRate: 48_000)
        let tracks = (1...6).map { TrackID("t\($0)") }
        for (n, track) in tracks.enumerated() {
            let file = FileID("f\(n + 1)")
            try session.addFile(AudioFile(id: file, path: "f\(n + 1).wav", layout: .mono, length: Frames(Self.frames)))
            try session.addTrack(track, name: "T\(n + 1)", layout: .mono)
            try session.place(
                Clip(id: ClipID("c\(n + 1)"), file: file, start: 0, offset: 0, length: Frames(Self.frames)), on: track)
        }
        _ = try session.splitClips(at: (1..<2000).map { Frames($0 * Self.frames / 2000) }, on: tracks)
        for n in 0..<200 {
            try session.setMarker(
                Marker(
                    id: MarkerID("m\(n)"), name: "M\(n)", position: Frames(n * Self.frames / 200 + 7_000), kind: .marker
                ))
        }
        #expect(session.tracks.allSatisfy { $0.clips.count == 2000 })
        let clip = Self.frames / 2000
        for (name, framesPerPoint) in [("fit", Double(Self.frames) / 1440), ("60 pt boxes", Double(clip) / 60)] {
            let geometry = try #require(
                LaneGeometry(scale: TimelineScale(framesPerPoint: framesPerPoint), laneHeight: 100))
            let excluded: Set<ClipID> = [session.tracks[0].clips[1000].id]
            let setUp = ContinuousClock.now
            let snap = Snap(session, excluding: excluded, geometry: geometry)
            let setUpTime = ContinuousClock.now - setUp
            var times: [Duration] = []
            var found = 0
            for n in 0..<120 {
                // A moved clip of one clip length whose start is 2 pt after a clip edge.
                let start = Frames(n * 16 * clip + Int(2 * framesPerPoint))
                let edges = [start, start + Frames(clip)]
                let begin = ContinuousClock.now
                let shifted = snap.shift(edges, playhead: Frames(Self.frames / 2))
                times.append(ContinuousClock.now - begin)
                if shifted != nil { found += 1 }
            }
            let p95 = times.sorted()[113]
            print("SnapSearchBenchmark \(name): p95 \(p95), set-up \(setUpTime), snapped \(found) of 120")
            // At 60 pt boxes each search finds a clip edge 2 pt away; at fit zoom the clips are under
            // 12 pt, so only a marker or the playhead can snap.
            #expect(name == "fit" || found == 120, "\(name): snapped \(found) of 120")
            #if DEBUG
                if p95 > Self.budget || setUpTime > Self.budget {
                    print("bench report: \(name) p95 \(p95), set-up \(setUpTime) over debug budget \(Self.budget)")
                }
            #else
                #expect(p95 <= Self.budget, "\(name): p95 \(p95)")
                #expect(setUpTime <= Self.budget, "\(name): set-up \(setUpTime)")
            #endif
        }
    }
}
