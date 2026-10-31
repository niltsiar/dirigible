import Foundation
import Testing

@testable import DirigibleAudio

/// C17: 1 h of Spanish `say` speech with the default model takes at most 30 min in an optimized
/// build (`make bench FILTER='WhisperEngineBenchmark TranscribeBenchmark'`, after
/// `scripts/fetch-whisper-test-model.sh`). The debug build skips the decode with a printed reason.
struct TranscribeBenchmark {
    static let budget = Duration.seconds(30 * 60)

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func anHourOfSpanishTakesAtMostThirtyMinutes() throws {
        #if DEBUG
            print("TranscribeBenchmark skip in the debug build: the decode of 1 h takes hours unoptimized")
        #else
            let speech = try WhisperEngineBenchmark.say(
                WhisperEngineBenchmark.spanish, voice: "Mónica", language: "es")
            var hour: [Float] = []
            while hour.count < 3_600 * 16_000 { hour += speech }
            hour.removeLast(hour.count - 3_600 * 16_000)
            let engine = try WhisperEngineBenchmark.engine()
            let pieces = 6
            let length = hour.count / pieces
            let start = ContinuousClock.now
            let result = try engine.transcribe(
                pieceCount: pieces, language: .code("es"), stop: StopFlag(),
                read: { Array(hour[($0 * length)..<(($0 + 1) * length)]) }, progress: { _ in })
            let elapsed = ContinuousClock.now - start
            print("TranscribeBenchmark 1 h of Spanish: \(elapsed)")
            let words = try #require(result).pieces.joined()
            #expect(words.count > 5_000)
            #expect(elapsed <= Self.budget)
        #endif
    }
}
