import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Read-by-time criterion C14 (decision 0062): the reads of a 66.5 min session of 2 stereo tracks
/// at 48 kHz fit their budgets in an optimized build (`make bench FILTER=ReadBenchmark`). A debug
/// build only prints. Each bench asserts its result, so a read that does no work fails.
struct ReadBenchmark {
    /// 2 stereo tracks, each of 399 clips of one 10 s block file (66.5 min): 9 s of a 1 kHz tone at
    /// a peak of 0.05 (-26 dBFS), then 1 s of digital silence (block frames 432 000 ..< 480 000).
    /// The two tracks sum to a peak of 0.1, so the tone of the mix reads -20 LUFS.
    static func fixture() throws -> (package: MixPackage, frames: Frames) {
        let package = try MixPackage()
        try package.addFile("block", channels: tone([(9, 20 * log10(0.05)), (1, -.infinity)]))
        let block = 480_000
        for track in ["t1", "t2"] {
            try package.addTrack(
                TrackID(track), layout: .stereo, clip: ClipID("\(track)-0"), file: "block", start: 0, offset: 0,
                length: Frames(block))
            for index in 1..<399 {
                try package.session.place(
                    Clip(
                        id: ClipID("\(track)-\(index)"), file: "block", start: Frames(index * block), offset: 0,
                        length: Frames(block)), on: TrackID(track))
            }
        }
        return (package, Frames(399 * block))
    }

    /// The budget is 2 times the first optimized time (5.08 s on the Intel Mac), rounded up to
    /// 0.5 s. 93 of the 100 blocks of 400 ms of each 10 s pass the gates and hold the
    /// power of 90 tone blocks, so the mix reads 0.14 LU under the tone.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func meterOfSixtySixMinutesFitsTheBudget() throws {
        let (package, frames) = try Self.fixture()
        let clock = ContinuousClock()
        let start = clock.now
        let read = try measureMix(of: nil, in: package.session, package: package.url, range: 0..<frames)
        let elapsed = clock.now - start

        print("bench report: meter of 66.5 min took \(elapsed)")
        expectLUFS(read.measure.integrated, -20, tolerance: 0.5, "the meter of the fixture")
        expectWithinBudget(elapsed, .milliseconds(10_500), "meter of 66.5 min took \(elapsed)")
    }

    /// The silences of the whole fixture and the nearest pause 0.3 s before the gap of the clip
    /// at frame 96 000 000, with the defaults: -40 dBFS, 500 ms and 200 ms, a 2 s window. The
    /// silences budget is 2 times the first optimized time (1.08 s on the Intel Mac), rounded up to
    /// 0.5 s; the pause budget of C14 (0.5 s) is already that rounding of 2 times 2.3 ms.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func silencesAndPauseFitTheBudget() throws {
        let (package, frames) = try Self.fixture()
        let threshold = Gain(dB: -40)!
        let clock = ContinuousClock()
        var start = clock.now
        let all = try mixLevels(
            of: nil, in: package.session, package: package.url, range: 0..<frames, silence: threshold)
        let silences = all.series.silences(threshold: threshold, minLength: 24_000, in: 0..<frames)
        let silencesTime = clock.now - start

        let at = Frames(96_000_000 + 417_600)
        start = clock.now
        let near = try mixLevels(
            of: nil, in: package.session, package: package.url, range: at - 96_000..<at + 96_000,
            silence: threshold)
        let pause = near.series.nearestPause(at: at, window: 96_000, threshold: threshold, minLength: 9_600)
        let pauseTime = clock.now - start

        print("bench report: silences of 66.5 min took \(silencesTime), nearest pause took \(pauseTime)")
        #expect(silences.count == 399, "silences of the fixture: \(silences.count)")
        #expect(pause == .pause(Frames(96_432_000)..<Frames(96_480_000), cut: 96_456_000), "\(pause)")
        expectWithinBudget(silencesTime, .milliseconds(2_500), "silences of 66.5 min took \(silencesTime)")
        expectWithinBudget(pauseTime, .milliseconds(500), "nearest pause took \(pauseTime)")
    }
}
