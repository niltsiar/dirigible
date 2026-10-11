import AppKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The time display during a take (ui-shell A19, run toolbar-time-take).
extension ChromeTests {
    /// During a take the time shows the record head with tenths, and the playhead stays at the take
    /// start. After the take it shows the playhead with milliseconds, and the head tick ends. The
    /// disk watch and the idle read turn no loop, so only the head tick moves the text.
    @Test func aTakeMovesTheTimeWithTheRecordHead() async throws {
        let (model, studio, chrome) = try await open()
        studio.environment.diskCheckInterval = .seconds(60)
        chrome.startTicker(every: .seconds(600))
        let time = try #require(chrome.time)
        var announced: [String] = []
        chrome.announce = { text, _ in announced.append(text) }
        await studio.perform(.seek(.frame(96_000)))
        await model.record()
        try #require(model.canStop, "the take runs")

        await until(limit: .seconds(5), "the time moves with the record head") {
            !["0:00:02.0", "0:00:02.000"].contains(time.text)
        }
        #expect(!["0:00:02.0", "0:00:02.000"].contains(time.text), "C1: \(time.text)")
        #expect(time.text.split(separator: ".").last?.count == 1, "C2: \(time.text)")
        #expect(studio.playhead == 96_000, "C3: the playhead moved during the take")
        #expect(time.accessibilityLabel() == L10n.toolbarTime.text, "C10: label")
        #expect(time.accessibilityValue() as? String == time.text, "C10: value")

        // Other suites can hold the main actor for seconds, so the lower bound waits for 3 changes
        // with a limit; the upper bound counts over the measured span.
        let changes = time.textChanges
        let start = ContinuousClock.now
        await until(limit: .seconds(30), "the head tick changes the time 3 times") { time.textChanges - changes >= 3 }
        try? await Task.sleep(for: .seconds(1))
        let seconds = (ContinuousClock.now - start) / .seconds(1)
        let count = time.textChanges - changes
        #expect(count >= 3 && Double(count) <= 10 * seconds + 1, "C4: \(count) changes in \(seconds) s")

        await hal.feed(seconds: 0.2)
        let reads = chrome.recordTimeReadsStarted
        await model.stop()
        var polled: [String] = []
        await until("the finalize ends") {
            polled.append(time.text)
            return studio.transport == .idle
        }
        #expect(!polled.contains("0:00:02.000"), "C5: the finalize shows the take start")
        let stopped = { timeDisplayText(studio.playhead, rate: 48_000, playing: false) }
        await until(limit: .seconds(5), "the time shows the playhead after the take") { time.text == stopped() }
        #expect(time.text == stopped(), "C6: \(time.text)")
        #expect(!announced.contains { $0.hasPrefix("0:0") }, "C10: a time announcement")

        // The idle flip starts a record time read; its write turns the loop once more.
        await until("the record time read after the take ends") {
            chrome.recordTimeReadsStarted > reads && chrome.recordTimeReads == chrome.recordTimeReadsStarted
        }
        await runLoopPass()
        let turns = chrome.turns
        try? await Task.sleep(for: .milliseconds(300))
        #expect(chrome.turns == turns, "C11: the loop turns after the take")
        await model.close()
    }
}
