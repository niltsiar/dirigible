import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Timeline-view criterion 9: 6 lanes of 2 h peaks into 2880 x 1200 px, at zoom to fit and at
/// the closest zoom, 120 draws each, with a p95 of 8 ms or less in an optimized build. `make test`
/// is unoptimized (a test run with -O runs the `dirigible` main), and this code measured a p95 of
/// 23 to 24 ms there, so the debug budget is 40 ms. A loop of one Swift step per pixel measured
/// 72 to 90 ms. For the optimized run, copy the package, make DirigibleApp a library target with no
/// `@main`, and run `swift test -c release -Xswiftc -enable-testing --filter LaneRenderBenchmark`
/// with the slow-test gate variable set to 1. (`make test-slow` counts each line that names it.)
struct LaneRenderBenchmark {
    #if DEBUG
        static let budget = Duration.milliseconds(40)
    #else
        static let budget = Duration.milliseconds(8)
    #endif

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func sixLanesOfTwoHoursDrawInTheBudget() throws {
        let frames = 345_600_000
        let peaks = randomPeaks(frames: frames)
        var session = Session(sampleRate: 48_000)
        var states: [FileID: PeakState] = [:]
        for n in 1...6 {
            let file = FileID("f\(n)")
            try session.addFile(AudioFile(id: file, path: "f\(n).wav", layout: .mono, length: Frames(frames)))
            try session.addTrack(TrackID("t\(n)"), name: "T\(n)", layout: .mono)
            try session.place(
                Clip(id: ClipID("c\(n)"), file: file, start: 0, offset: 0, length: Frames(frames)), on: TrackID("t\(n)")
            )
            states[file] = .ready(peaks)
        }
        let renderer = LaneRenderer()

        for (zoom, framesPerPoint) in [("fit", Double(frames) / 1440), ("closest", 128.0)] {
            let inputs = LaneInputs(
                session: session, peaks: states, missingMedia: [:], marks: Marks(),
                scale: TimelineScale(framesPerPoint: framesPerPoint), laneHeight: 100)
            var times: [Duration] = []
            for draw in 0..<120 {
                let start = ContinuousClock.now
                _ = renderer.draw(inputs, x: Double(draw % 7), width: 1440, scale: 2)
                times.append(ContinuousClock.now - start)
            }
            let p95 = times.sorted()[113]
            #expect(renderer.columns == 2880 && renderer.rows == 1200)
            #expect(p95 <= Self.budget, "\(zoom): p95 \(p95)")
        }
    }
}

/// Code gate 1 item 3: a draw of 10 pt of 6 lanes of 1000 clips each labels only the clips in the
/// dirty rect. Unoptimized, on the MacBook Pro 2018 of the probes: a median of 10.5 s when the
/// labels looked up every clip of the session by its ID, 8.5 ms after the fix.
@MainActor struct ClipLabelBenchmark {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aNarrowDrawOfManyClipsReadsOnlyItsClips() throws {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f1", path: "f1.wav", layout: .mono, length: 4800))
        for track in 1...6 {
            try session.addTrack(TrackID("t\(track)"), name: "T\(track)", layout: .mono)
            for n in 0..<1000 {
                try session.place(
                    Clip(id: ClipID("c\(track)x\(n)"), file: "f1", start: Frames(n * 4800), offset: 0, length: 4800),
                    on: TrackID("t\(track)"))
            }
        }
        let view = documentView(session)
        let rect = NSRect(x: 4000, y: 0, width: 10, height: 600)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: rect))

        var times: [Duration] = []
        for _ in 0..<20 {
            let start = ContinuousClock.now
            view.cacheDisplay(in: rect, to: bitmap)
            times.append(ContinuousClock.now - start)
        }
        let median = times.sorted()[10]
        #expect(median <= .milliseconds(20), "median \(median)")
    }
}

/// SplitMix64, so the benchmark draws the same peaks on each run.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
