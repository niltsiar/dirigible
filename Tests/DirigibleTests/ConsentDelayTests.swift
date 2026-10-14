import AppKit
import DirigibleCore
import DirigibleMCP
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The click delay of the consent sheet (decision 0050, C8): Record is disabled until the sheet
/// window was key for 1 s with no break. The tests give the key state; the on-screen check of S2
/// covers the key observers.
extension ConsentTests {
    /// A sheet with the 1 s delay and a fake clock. The wait of the delay ends when the fake
    /// clock passes its end.
    struct Delayed {
        let model: SessionWindow
        let studio: Studio
        let sheet: NSWindow
        let answer: Task<RecordAnswer, Never>
        let clock: Clock

        @MainActor final class Clock {
            var now = ContinuousClock.now
        }

        @MainActor var record: NSButton? { sheetButton(cancel: false, in: sheet) }

        /// The sheet window becomes key or resigns, as the key observers of the window give it.
        @MainActor func key(_ became: Bool) {
            if let consent = model.consent { model.sheetKey(consent, became: became) }
        }

    }

    func delayed() async throws -> Delayed {
        let (model, studio) = try await window()
        let clock = Delayed.Clock()
        model.agentRecord.clickDelay = .seconds(1)
        model.agentRecord.followsKey = false
        model.agentRecord.now = { clock.now }
        model.agentRecord.delayWait = { end in
            while clock.now < end, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
        }
        let answer = ask(model)
        let sheet = try await sheet(model)
        return Delayed(model: model, studio: studio, sheet: sheet, answer: answer, clock: clock)
    }

    /// Presses Record and checks that nothing happened: the sheet waits and nothing records.
    func pressRecordsNothing(_ d: Delayed, _ comment: Comment) throws {
        let record = try #require(d.record)
        #expect(!record.isEnabled, comment)
        record.performClick(nil)
        #expect(d.model.consent?.phase == .waiting && d.studio.transport == .idle, comment)
    }

    @Test func recordIsDisabledBeforeOneSecond() async throws {
        let d = try await delayed()
        d.key(true)
        d.clock.now += .seconds(0.5)
        try pressRecordsNothing(d, "key for 0.5 s")
        await d.model.answerConsent(record: true)
        #expect(d.model.consent?.phase == .waiting, "the window function also waits for 1 s")
        await d.model.answerConsent(record: false)
        #expect(await d.answer.value == .declined)
        await d.model.close()
    }

    @Test func recordIsEnabledAfterOneSecond() async throws {
        let d = try await delayed()
        d.key(true)
        d.clock.now += .seconds(1.1)
        await until("Record is enabled after 1.1 s") { d.record?.isEnabled == true }
        try #require(d.record).performClick(nil)
        #expect(await d.answer.value == .started(take: 1, tracks: ["Host"], seconds: 30))
        await d.model.stop()
        await d.model.close()
    }

    /// The time before the sheet was key does not count.
    @Test func timeBeforeTheKeyDoesNotCount() async throws {
        let d = try await delayed()
        d.clock.now += .seconds(2)
        try pressRecordsNothing(d, "not key")
        d.key(true)
        d.clock.now += .seconds(0.5)
        try pressRecordsNothing(d, "not key for 2 s, then key for 0.5 s")
        await d.model.answerConsent(record: false)
        #expect(await d.answer.value == .declined)
        await d.model.close()
    }

    /// A resign starts the count again, and disables Record.
    @Test func aResignStartsAgain() async throws {
        let d = try await delayed()
        d.key(true)
        d.clock.now += .seconds(0.6)
        d.key(false)
        d.key(true)
        d.clock.now += .seconds(0.5)
        try pressRecordsNothing(d, "key 0.6 s, a resign, key 0.5 s")

        d.clock.now += .seconds(0.6)
        await until("Record is enabled after 1.1 s of key time") { d.record?.isEnabled == true }
        d.key(false)
        await until("Record is disabled at the resign") { d.record?.isEnabled == false }
        try pressRecordsNothing(d, "a resign after 1.1 s")
        await d.model.answerConsent(record: false)
        #expect(await d.answer.value == .declined)
        await d.model.close()
    }

    /// Don't Record and Escape act at once.
    @Test(arguments: [false, true]) func declineActsAtOnce(escape: Bool) async throws {
        let d = try await delayed()
        if escape { press("\u{1b}", code: 53, in: d.sheet) } else { try click(record: false, in: d.sheet) }
        #expect(await d.answer.value == .declined)
        await d.model.close()
    }
}
