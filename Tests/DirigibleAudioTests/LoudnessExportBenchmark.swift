import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Run 9a criterion 21: the 2 h, 8-track fixture of `ExportBenchmark` exports to WAV 16 stereo
/// with the podcast target (pass 1, the limiter, and the dither) in 57 s or less, optimized
/// build (`make bench FILTER=LoudnessExportBenchmark`). The fixture has no limiting, so it runs
/// no trial pass. The first optimized run took 28.4 s, and the budget is 2 times that. So it
/// catches a slowdown of 2 times, not each loss of speed: a scalar FIR in place of vDSP takes
/// 37.5 s and passes (control c17). A debug build exports 10 min and only prints.
struct LoudnessExportBenchmark {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aTwoHourNormalizedExportFitsTheBudget() throws {
        let steps = try Self.exportTwoHours(peaky: false, budget: .seconds(57))

        #expect(steps.trials == 0, "a mix under the ceiling ran \(steps.trials) trial passes")
    }

    /// Exports the 8 tracks to WAV 16 with podcast, and gives the passes that the search ran. The
    /// line has the renders (pass 1, each trial pass, each write) and the trial passes.
    static func exportTwoHours(peaky: Bool, budget: Duration) throws -> (trials: Int, writes: Int) {
        #if DEBUG
            let blocks = 60
        #else
            let blocks = 720
        #endif
        let (package, frames) = try ExportBenchmark.eightTracks(blocks: blocks, peaky: peaky)
        let out = package.folder.url.appending(path: "mix.wav")
        var steps: [LoudnessSearch.Step] = []
        var tuning = ExportTuning()
        tuning.onStep = { steps.append($0) }

        let clock = ContinuousClock()
        let start = clock.now
        let result = try exportMix(
            package.session, source: #require(ExportSource(range: 0..<frames)),
            options: ExportOptions(format: .wav(.bits16), layout: .stereo, rate: .session, loudness: .podcast),
            to: out, package: { package.url }, tuning: tuning)
        let elapsed = clock.now - start

        let trials = steps.filter { if case .trial = $0 { true } else { false } }.count
        let writes = steps.filter { if case .write = $0 { true } else { false } }.count
        print(
            "LoudnessExportBenchmark: \(blocks * 10) s of 8 tracks to WAV 16 with podcast in \(elapsed): "
                + "\(1 + trials + writes) renders, \(trials) trial passes, \(writes) writes")
        #expect(result.faults == [:])
        expectLUFS(result.loudness?.output, -16, "the output loudness")
        #expect(try AVAudioFile(forReading: out).length == AVAudioFramePosition(frames.count))
        expectWithinBudget(elapsed, budget, "the export took \(elapsed)")
        return (trials, writes)
    }
}
