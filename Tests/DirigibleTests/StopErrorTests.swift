import AppKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The Stop alert of a writer that does not stop (decision 0030): it names the control that
/// finishes the pending take, and Quit does not wait for the writer.
extension ChromeTests {
    /// Records on `t1`, holds the detach of `duo`, and clicks Stop, so the writer misses the stop
    /// deadline. A stop that does not return in 5 s is an issue; then the hold ends.
    func stopWithAHeldWriter() async throws -> (SessionWindow, Studio) {
        let (model, studio, _) = try await open(tracks: 1)
        studio.environment.stopLimit = .milliseconds(300)
        studio.environment.stopGrace = .zero
        model.armed = ["t1"]
        await model.record()
        try #require(model.canStop, "the take runs")
        await hal.feed(seconds: 0.5)
        // The fed records have host times up to 0.5 s from now; the stop writes no later record.
        try await Task.sleep(for: .milliseconds(600))
        hal.holdDetach()
        let stop = Task { @MainActor in await model.stop() }
        await until(limit: .seconds(5), "the stop waits for the held writer") { studio.transport == .idle }
        if studio.transport != .idle { hal.releaseDetach() }
        await stop.value
        return (model, studio)
    }

    @Test func theStopErrorNamesAControlThatFinishesTheTake() async throws {
        defer { hal.releaseDetach() }
        let (model, studio) = try await stopWithAHeldWriter()

        #expect(model.alert == .error(.writerDidNotStop("Duo")))
        #expect(model.alert?.text == L10n.errorWriterDidNotStop.format("Duo", L10n.menuRecordRetry.text))
        let texts = [
            "en": "Dirigible could not stop Duo. The audio is safe on disk. Click Retry Finalize to try again, or "
                + "quit Dirigible: the next launch restores the take.",
            "es": "Dirigible no pudo detener Duo. El audio está a salvo en el disco. Pulsa Reintentar la finalización "
                + "para intentarlo de nuevo, o sal de Dirigible: el próximo arranque restaura la toma.",
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
