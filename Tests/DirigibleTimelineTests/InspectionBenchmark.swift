import DirigibleCore
import Foundation
import Testing

@testable import DirigibleTimeline

/// K2: the inspector of a Select All at 2 h (6 tracks, 2,000 clips each) builds its value, makes
/// the typed gain, and sets it in one `History.edit`, with a p95 of 16 ms or less in an optimized
/// build (`make bench FILTER=InspectionBenchmark`). `make test-slow` runs it unoptimized with a
/// budget of 200 ms, a proxy only.
struct InspectionBenchmark {
    #if DEBUG
        static let budget = Duration.milliseconds(200)
    #else
        static let budget = Duration.milliseconds(16)
    #endif

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func inspectorOfSelectAllFitsOneFrame() throws {
        let hour = Frames(172_800_000)
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f", path: "f.wav", layout: .mono, length: hour + hour))
        for n in 1...6 { try session.addTrack(TrackID("t\(n)"), name: "T\(n)", layout: .mono) }
        for n in 0..<2_000 {
            let start = Frames(n * 172_800)
            try session.place(
                Clip(id: ClipID("c\(n)"), file: "f", start: start, offset: start, length: 168_000), on: "t1")
        }
        let first = try session.excerpt(of: .zero..<(hour + hour), on: Array(repeating: "t1", count: 5))
        try session.paste(first, at: .zero, on: ["t2", "t3", "t4", "t5", "t6"])
        let all = Marks(inPoint: .zero, outPoint: hour + hour, tracks: Set(session.tracks.map(\.id)))
        let history = History(session)

        var times: [Duration] = []
        for _ in 0..<20 {
            var copy = history
            let start = ContinuousClock.now
            let inspection = try #require(ClipInspection(marks: all, session: copy.session))
            let gains = try #require(ClipInspection.gains(-6, for: inspection.clips, in: copy.session))
            try copy.edit { session throws(SessionError) in try session.setGains(gains) }
            times.append(ContinuousClock.now - start)
            #expect(inspection.clips.count == 12_000 && gains.count == 12_000 && copy.canUndo)
        }
        let p95 = times.sorted()[18]
        print("InspectionBenchmark inspector of Select All: p95 \(p95)")
        #if DEBUG
            if p95 > Self.budget { print("bench report: p95 \(p95) over debug budget \(Self.budget)") }
        #else
            #expect(p95 <= Self.budget, "inspector of Select All: p95 \(p95)")
        #endif
    }
}
