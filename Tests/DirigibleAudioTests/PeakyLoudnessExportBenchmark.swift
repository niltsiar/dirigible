import Foundation
import Testing

@testable import DirigibleAudio

/// Export-loudness criterion C12 (b): the 8 tracks of `ExportBenchmark` with the "train" bursts
/// export to WAV 16 stereo with the podcast target in 120 s or less, optimized build
/// (`make bench FILTER=PeakyLoudnessExportBenchmark`). The limiter takes 1 LU, so the gain search
/// runs trial passes before the write. A debug build exports 10 min and only prints.
struct PeakyLoudnessExportBenchmark {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aTwoHourPeakyExportFitsTheBudget() throws {
        let steps = try LoudnessExportBenchmark.exportTwoHours(peaky: true, budget: .seconds(120))

        #expect(steps.trials >= 3, "the search ran \(steps.trials) trial passes")
    }
}
