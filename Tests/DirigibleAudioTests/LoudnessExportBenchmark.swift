import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Run 9a criterion 21: the 2 h, 8-track fixture of `ExportBenchmark` exports to WAV 16 stereo
/// with the podcast target (two passes, the limiter, and the dither) in 57 s or less, optimized
/// build (`make bench FILTER=LoudnessExportBenchmark`). The first optimized run took 28.4 s, and
/// the budget is 2 times that. A debug build exports 10 min and only prints.
struct LoudnessExportBenchmark {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aTwoHourNormalizedExportFitsTheBudget() throws {
        #if DEBUG
            let blocks = 60
        #else
            let blocks = 720
        #endif
        let (package, frames) = try ExportBenchmark.eightTracks(blocks: blocks)
        let out = package.folder.url.appending(path: "mix.wav")

        let clock = ContinuousClock()
        let start = clock.now
        let result = try exportMix(
            package.session, source: #require(ExportSource(range: 0..<frames)),
            options: ExportOptions(format: .wav(.bits16), layout: .stereo, rate: .session, loudness: .podcast),
            to: out, package: { package.url })
        let elapsed = clock.now - start

        print("LoudnessExportBenchmark: \(blocks * 10) s of 8 tracks to WAV 16 with podcast in \(elapsed)")
        #expect(result.faults == [:])
        expectLUFS(result.loudness?.output, -16, "the output loudness")
        #expect(try AVAudioFile(forReading: out).length == AVAudioFramePosition(frames.count))
        expectWithinBudget(elapsed, .seconds(57), "the export took \(elapsed)")
    }
}
