import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Compares a time with its budget. With -O (`make bench`), a miss fails the test. In debug, the
/// budget is a proxy that the load of the suite moves, so a miss only prints a report line.
func expectWithinBudget(
    _ value: Duration, _ budget: Duration, _ message: String, sourceLocation: SourceLocation = #_sourceLocation
) {
    #if DEBUG
        if value > budget { print("bench report: \(message) over debug budget \(budget)") }
    #else
        #expect(value <= budget, "\(message)", sourceLocation: sourceLocation)
    #endif
}

/// Timeline-view criterion 11: a 2 h mono WAV computes in 3 s or less (probe P1: 0.4 s warm).
struct PeakComputeBenchmark {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func twoHoursComputeInThreeSeconds() async throws {
        let folder = try TemporaryFolder()
        let url = folder.url.appending(path: "long.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let block = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480_000))
        block.frameLength = 480_000
        let tone = sine(seconds: 10, rate: 48_000, frequency: 375)
        block.floatChannelData![0].update(from: tone, count: tone.count)
        let writer = try ClipWriter(url: url, file: "long.wav", format: format)
        for _ in 0..<720 { try writer.write(block) }
        try writer.close()
        let file = try AVAudioFile(forReading: url)

        let clock = ContinuousClock()
        let start = clock.now
        let peaks = try await computePeaks(file, stamp: FileStamp(size: 0, seconds: 0, nanoseconds: 0)) { .go }
        let elapsed = clock.now - start

        #expect(peaks.frames == 345_600_000)
        #expect(peaks.levels[0].count == 1_350_000)
        expectWithinBudget(elapsed, .seconds(3), "the compute took \(elapsed)")
    }
}
