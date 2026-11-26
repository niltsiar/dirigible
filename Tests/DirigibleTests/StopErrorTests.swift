import AppKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The Stop alert of a writer that does not stop (decision 0030): it names the control that
/// finishes the pending take, and Quit does not wait for the writer.
extension ChromeTests {
    /// Records on `t1`, holds the detach of `duo`, and clicks Stop (or presses Space with `space`),
    /// so the writer misses the stop deadline. A stop that does not return in 5 s is an issue; then
    /// the hold ends. Then waits up to 5 s for the alert, and gives Retry Finalize the default stop
    /// limit, so a slow finish after the release does not miss it.
    func stopWithAHeldWriter(space: Bool = false) async throws -> (SessionWindow, Studio) {
        let (model, studio, _) = try await open(tracks: 1)
        studio.environment.stopLimit = .milliseconds(300)
        model.armed = ["t1"]
        await model.record()
        try #require(model.canStop, "the take runs")
        await hal.feed(seconds: 0.5)
        // The fed records have host times up to 0.5 s from now; the stop writes no later record.
        try await Task.sleep(for: .milliseconds(600))
        hal.holdDetach()
        let stop = Task { @MainActor in
            if space { model.transport(.playStop) } else { await model.stop() }
        }
        await until(limit: .seconds(5), "the stop waits for the held writer") { studio.transport == .idle }
        if studio.transport != .idle { hal.releaseDetach() }
        await stop.value
        await until(limit: .seconds(5), "no alert after the stop") { model.alert != nil }
        studio.environment.stopLimit = .seconds(10)
        return (model, studio)
    }

    /// Space stops the take through the transport, not through the Stop button, and shows the same
    /// alert.
    @Test(arguments: [false, true])
    func eachStopShowsTheAlertOfAWriterThatDidNotStop(space: Bool) async throws {
        defer { hal.releaseDetach() }
        let (model, studio) = try await stopWithAHeldWriter(space: space)

        #expect(model.alert == .error(.writerDidNotStop("Duo")))
        hal.releaseDetach()
        await model.retry()
        #expect(studio.pendingTake == nil, "Retry Finalize did not finish the take")
        await model.close()
    }

    @Test func theStopErrorNamesAControlThatFinishesTheTake() async throws {
        defer { hal.releaseDetach() }
        let (model, studio) = try await stopWithAHeldWriter()

        #expect(model.alert == .error(.writerDidNotStop("Duo")))
        #expect(model.alert?.text == L10n.errorWriterDidNotStop.format("Duo", L10n.menuRecordRetry.text))
        let texts = [
            "en": "The recording of Duo didn't stop. Click Retry Finalize to try again.",
            "es": "La grabación de Duo no se detuvo. Pulsa Reintentar la finalización para intentarlo de nuevo.",
        ]
        for (language, expected) in texts {
            let table = try stringsTable(language)
            let format = table["error.writer.did.not.stop"] ?? ""
            #expect(String(format: format, "Duo", table["menu.record.retry"] ?? "") == expected, "\(language)")
        }
        #expect(model.canRetry && !model.canStop)
        hal.releaseDetach()
        await model.retry()
        #expect(studio.pendingTake == nil && studio.takeError == nil, "Retry Finalize did not finish the take")
        await model.close()
    }

    @Test func aQuitAfterTheStopErrorDoesNotWaitForTheWriter() async throws {
        defer { hal.releaseDetach() }
        let (model, studio) = try await stopWithAHeldWriter()
        #expect(studio.pendingTake != nil)

        app.confirmQuit = { _, _, _ in true }
        // The reply goes to the test, not to AppKit, so the test process does not quit.
        var reply: Bool?
        app.replyToTerminate = { reply = $0 }
        let answer = app.applicationShouldTerminate(NSApp)
        if answer == .terminateLater { await until(limit: .seconds(5), "Quit waits for the writer") { reply != nil } }

        #expect(answer == .terminateNow || reply == true, "\(answer), \(String(describing: reply))")
        hal.releaseDetach()
        await model.close()
    }
}
