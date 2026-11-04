import DirigibleCore
import DirigibleMCP
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
}
