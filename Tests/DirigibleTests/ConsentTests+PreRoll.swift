import AppKit
import DirigibleCore
import DirigibleMCP
import Foundation
import SwiftUI
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// An agent record request with `pre_roll` (criteria P14 and P27 of run 2026-10-28-pre-roll).
extension ConsentTests {
    /// P14: Record of the sheet starts a pre-roll take, and the answer names the pre-roll.
    @Test func sheetTakeHasThePreRoll() async throws {
        let (model, studio) = try await window()
        let request = RecordRequest(armed: ["t1"], seconds: 30, playhead: 48_000, preRoll: 1)
        let answer = Task { await model.askRecord(request, agent: agent) }
        try click(record: true, in: try await sheet(model))

        #expect(await answer.value == .started(take: 1, tracks: ["Host"], seconds: 30, preRoll: 1))
        #expect(studio.session.recording?.isPreRoll == true && studio.session.recording?.playheadFrame == 48_000)
        await model.stop()
        await model.close()
    }

    /// U16: a request with `pre_roll` that the window grant covers starts a pre-roll take with no
    /// sheet, and the answer names the pre-roll.
    @Test func grantTakeHasThePreRoll() async throws {
        let (model, studio) = try await window()
        try await giveGrant(model, studio)
        let request = RecordRequest(armed: ["t1"], seconds: 0.3, playhead: 48_000, preRoll: 1)

        let answer = await model.askRecord(request, agent: agent, connection: Self.seven)

        guard case .started(2, ["Host"], 0.3, 1, let grant?) = answer, grant.noSheet else {
            Issue.record("no grant take with the pre-roll: \(answer)")
            return await model.close()
        }
        #expect(studio.session.recording?.isPreRoll == true)
        await model.stop()
        await model.close()
    }

    /// The sheet, the take, and the answer give the pre-roll that plays: a request near the session
    /// start gets the whole seconds before the start, and a request at the start gets no pre-roll.
    @Test(arguments: [(48_000, 1), (72_000, 1), (0, nil)] as [(Int, Int?)])
    func preRollIsCutAtTheSessionStart(playhead: Int, played: Int?) async throws {
        let (model, studio) = try await window()
        let request = RecordRequest(armed: ["t1"], seconds: 30, playhead: Frames(playhead), preRoll: 3)
        let answer = Task { await model.askRecord(request, agent: agent) }
        let sheet = try await sheet(model)
        #expect(model.consent?.preRoll == played, "the sheet line")
        try click(record: true, in: sheet)

        #expect(await answer.value == .started(take: 1, tracks: ["Host"], seconds: 30, preRoll: played))
        #expect(studio.session.recording?.isPreRoll == (played != nil))
        await model.stop()
        await model.close()
    }

    /// The agent take row, the notification, and the Dock text count the length from the take start
    /// H_T, not from the start of the pre-roll. The table of a test process has no text, so the
    /// on-screen check reads the row.
    @Test func agentTakeRowCountsFromTheTakeStart() async throws {
        let (model, studio) = try await window()
        // The offline Player plays the pre-roll at once; a paced one plays it in real time.
        studio.environment.playerOutput = .paced
        let request = RecordRequest(armed: ["t1"], seconds: 30, playhead: 96_000, preRoll: 2)
        let answer = Task { await model.askRecord(request, agent: agent) }
        try click(record: true, in: try await sheet(model))
        _ = await answer.value
        let take = try #require(model.agentRecord.take)
        let start = try #require(studio.session.recording?.takeStartHostTimeNanos)
        let (host, now) = (studio.environment.hostNanos(), ContinuousClock.now)
        let takeStart = start > host ? now + .nanoseconds(start - host) : now - .nanoseconds(host - start)

        let gap: Duration = take.since - takeStart
        #expect(gap > .milliseconds(-100) && gap < .milliseconds(100), "since \(gap) from H_T")
        await model.stop()
        await model.close()
    }

    /// P27: one sentence names the start and the pre-roll length, in English and Spanish.
    @Test func preRollLine() throws {
        for (language, line) in [
            ("en", "Starts recording at 1:02:03, after a 3 s pre-roll."),
            ("es", "Empieza a grabar en 1:02:03, después de un pre-roll de 3 s."),
        ] {
            let table = try stringsTable(language)
            let text = consentPreRollText(
                start: "1:02:03", seconds: 3, locale: Locale(identifier: language), text: { table[$0.rawValue] ?? "" })
            #expect(text == line, "\(language)")
        }
    }

    /// P27: a request with a pre-roll makes the sheet taller by one line of text and the stack
    /// spacing (12), not by a second line under the message. SwiftUI gives a test no text of the
    /// sheet, so the test measures the real sheet.
    @Test func preRollLineIsOneLine() async throws {
        let (model, _) = try await window()
        var heights: [CGFloat] = []
        for preRoll in [nil, 3] {
            let request = RecordRequest(armed: ["t1"], seconds: 30, playhead: 48_000, preRoll: preRoll)
            let answer = Task { await model.askRecord(request, agent: agent) }
            heights.append(try await sheet(model).frame.height)
            await model.answerConsent(record: false)
            #expect(await answer.value == .declined)
            await until("the sheet goes") { model.window?.attachedSheet == nil }
        }
        await model.close()
        let text = consentPreRollText(start: timeDisplayText(48_000, rate: 48_000, playing: false), seconds: 3)
        let line = NSHostingView(rootView: Text(verbatim: text)).fittingSize.height
        #expect(
            heights[0] > 0 && abs(heights[1] - heights[0] - (line + 12)) < 1, "sheet heights \(heights), line \(line)")
    }
}
