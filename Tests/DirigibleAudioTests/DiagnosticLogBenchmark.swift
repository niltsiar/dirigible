import Foundation
import Testing

@testable import DirigibleAudio

/// P1 of run 2026-10-16-diagnostics: the caller of `note` waits 20 us or less at p99 and 10 us or
/// less on average, optimized (`make bench FILTER=DiagnosticLogBenchmark`; a debug run only prints).
/// A take start writes about 40 lines on the main actor: 0.8 ms at the budget, under one frame.
struct DiagnosticLogBenchmark {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aNoteCostsItsCallerLittle() throws {
        let folder = try TemporaryFolder()
        let log = startLog(in: folder.url)
        let uid = "AppleUSBAudioEngine:Unknown:USB PnP Sound Device:14200000:1"
        let clock = ContinuousClock()
        var times: [Duration] = []
        times.reserveCapacity(20_000)
        for index in 0..<20_000 {
            let start = clock.now
            log.note(
                .device, "attach",
                [
                    "device": .text("USB PnP Sound Device"), "uid": .uid(uid), "ms": .number(Int64(index % 97)),
                    "status": .number(0),
                ])
            times.append(clock.now - start)
            // A pause after each 1000 lines, so the queue drains as in a take.
            if index % 1000 == 999 { usleep(1000) }
        }
        log.drain()

        let sorted = times.sorted()
        let (p99, mean) = (sorted[19_800], times.reduce(.zero, +) / 20_000)
        print("bench report: a journal note: mean \(mean), p99 \(p99), max \(sorted[19_999])")
        expectWithinBudget(p99, .microseconds(20), "a journal note: p99 \(p99)")
        expectWithinBudget(mean, .microseconds(10), "a journal note: mean \(mean)")
        // The work happened: the file holds each line after the preamble.
        let lines = try journalLines(of: try #require(journalFiles(in: folder.url).first))
        #expect(lines.count == 20_003)
    }
}
