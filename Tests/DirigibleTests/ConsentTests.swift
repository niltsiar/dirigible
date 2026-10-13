import AppKit
import DirigibleCore
import DirigibleMCP
import Foundation
import Testing
import os

@testable import DirigibleApp
@testable import DirigibleAudio

/// The consent sheet of an agent record request (decision 0048), on real windows with the
/// counting HAL. The buttons and keys go to the real sheet.
@Suite(.serialized) @MainActor struct ConsentTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)
    let hal = CountingHAL()
    let agent = AgentName(title: "Claude Code", clientName: "claude-code")

    init() throws { folder = try TemporaryFolder() }

    /// `t1` "Host" (mono) on channel 1 of `duo`, and `t2` "Guest" (stereo) with no route.
    func window(_ name: String = "consent") async throws -> (SessionWindow, Studio) {
        let url = folder.url.appending(path: "\(name).dirigible")
        try await Task.detached {
            var session = Session(sampleRate: 48_000)
            try session.addTrack("t1", name: "Host", layout: .mono)
            try session.addTrack("t2", name: "Guest", layout: .stereo)
            try session.setRoute(.device(uid: "duo", channels: .mono(1)), track: "t1")
            try session.write(to: url)
        }.value
        let model = await app.open(url)
        let studio = try #require(await model.opened() ? model.studio : nil)
        studio.environment = hal.environment
        model.attention = ConsentAttention(isActive: { true }, request: { 0 }, cancel: { _ in })
        return (model, studio)
    }

    func ask(
        _ model: SessionWindow, _ armed: [TrackID] = ["t1"], seconds: Double = 30, playhead: Frames? = nil
    ) -> Task<RecordAnswer, Never> {
        let request = RecordRequest(armed: armed, seconds: seconds, playhead: playhead)
        return Task { await model.askRecord(request, agent: agent) }
    }

    /// Waits for the sheet of a waiting request and gives it.
    func sheet(_ model: SessionWindow) async throws -> NSWindow {
        await until("the consent sheet shows") {
            model.consent?.phase == .waiting && model.window?.attachedSheet != nil
        }
        let sheet = try #require(model.window?.attachedSheet)
        sheet.contentView?.layoutSubtreeIfNeeded()
        return sheet
    }

    func press(_ characters: String, code: UInt16, in sheet: NSWindow) {
        let event = key(.keyDown, characters, code: code, in: sheet)
        if !sheet.performKeyEquivalent(with: event) { sheet.sendEvent(event) }
    }

    func click(record: Bool, in sheet: NSWindow) throws {
        try #require(sheetButton(cancel: !record, in: sheet)).performClick(nil)
    }

    // MARK: C3, C4, C11

    /// C3: the sheet shows and nothing records; Record starts a take on the request tracks only,
    /// and the window armed set does not change.
    @Test func recordClickStartsTheTake() async throws {
        let (model, studio) = try await window()
        model.armed = ["t2"]
        let answer = ask(model)
        let sheet = try await sheet(model)
        #expect(studio.transport == .idle && studio.session.recording == nil, "nothing records before the click")

        try click(record: true, in: sheet)

        #expect(await answer.value == .started(take: 1, tracks: ["Host"], seconds: 30))
        #expect(studio.transport == .recording(take: 1))
        #expect(studio.session.recording?.armedTracks == ["t1"])
        #expect(model.armed == ["t2"], "the window armed set stays")
        #expect(model.consent == nil)
        await model.stop()
        await model.close()
    }

    /// C3: the take starts at the frame of the request, else at the playhead of the ask.
    @Test(arguments: [Frames(48_000), nil]) func playheadOfTheRequest(playhead: Frames?) async throws {
        let (model, studio) = try await window()
        let answer = ask(model, playhead: playhead)
        let sheet = try await sheet(model)
        try click(record: true, in: sheet)
        #expect(await answer.value == .started(take: 1, tracks: ["Host"], seconds: 30))
        #expect(studio.session.recording?.playheadFrame == playhead ?? 0)
        await model.stop()
        await model.close()
    }

    /// C4: Don't Record and Escape decline: no take, no undo entry, no save.
    @Test(arguments: [false, true]) func declineRecordsNothing(escape: Bool) async throws {
        let (model, studio) = try await window()
        let revision = studio.sessionRevision
        let answer = ask(model)
        let sheet = try await sheet(model)

        if escape { press("\u{1b}", code: 53, in: sheet) } else { try click(record: false, in: sheet) }

        #expect(await answer.value == .declined)
        #expect(studio.transport == .idle && studio.session.recording == nil)
        #expect(studio.sessionRevision == revision && !studio.canUndo)
        #expect(model.consent == nil)
        await until("the sheet goes") { model.window?.attachedSheet == nil }
        await model.close()
    }

    /// C11: no button takes Return, so a Return while the sheet shows records nothing. Escape
    /// then proves that the keys reach the sheet.
    @Test func returnDoesNotRecord() async throws {
        let (model, studio) = try await window()
        let answer = ask(model)
        let sheet = try await sheet(model)
        let record = try #require(sheetButton(cancel: false, in: sheet))
        #expect(record.keyEquivalent.isEmpty, "Record has no key")

        press("\r", code: 36, in: sheet)

        #expect(model.consent?.phase == .waiting && studio.transport == .idle, "Return records nothing")
        press("\u{1b}", code: 53, in: sheet)
        #expect(await answer.value == .declined)
        await model.close()
    }

    // MARK: C5, C6

    /// C5: with no answer the sheet closes, nothing records, and the info banner names the agent.
    @Test func expiryClosesTheSheet() async throws {
        let (model, studio) = try await window()
        model.consentLifetime = .milliseconds(200)
        let answer = ask(model)

        #expect(await answer.value == .noAnswer)
        #expect(studio.transport == .idle && model.consent == nil)
        await until("the sheet goes") { model.window?.attachedSheet == nil }
        let text = L10n.bannerConsentExpired.format("Claude Code")
        await until("the banner shows") { model.shown.banners.contains { $0.text == text } }
        await model.close()
    }

    /// C5: a click before the end records, and the end after the click does nothing.
    @Test func clickBeforeExpiryRecords() async throws {
        let (model, studio) = try await window()
        model.consentLifetime = .seconds(2)
        let answer = ask(model)
        let sheet = try await sheet(model)
        try click(record: true, in: sheet)
        #expect(await answer.value == .started(take: 1, tracks: ["Host"], seconds: 30))
        try await Task.sleep(for: .milliseconds(2500))
        #expect(studio.transport == .recording(take: 1), "the end after the click stops nothing")
        #expect(model.consentExpired == nil)
        await model.stop()
        await model.close()
    }

    /// C5: the activity token lives from the ask to the end, so App Nap does not delay the end.
    @Test func activityLivesWithTheRequest() async throws {
        let (model, _) = try await window()
        let answer = ask(model)
        let sheet = try await sheet(model)
        let consent = try #require(model.consent)
        #expect(consent.activity != nil)
        try click(record: false, in: sheet)
        #expect(await answer.value == .declined)
        #expect(consent.activity == nil)
        await model.close()
    }

    /// The microphone prompt of the window waits for `give` and then grants the access.
    func holdPrompt(_ model: SessionWindow, _ studio: Studio) -> (asked: () -> Bool, give: () -> Void) {
        let granted = OSAllocatedUnfairLock(initialState: false)
        studio.environment.microphoneAccess = { granted.withLock { $0 } ? nil : .notDetermined }
        let (answer, give) = AsyncStream<Void>.makeStream()
        var asked = false
        model.requestMicrophoneAccess = {
            asked = true
            for await _ in answer { break }
            granted.withLock { $0 = true }
            return true
        }
        return ({ asked }, { give.yield() })
    }

    /// C6: during the start, the end of the answer time and a second Record do nothing; the one
    /// reply is the start.
    @Test func eachEndRepliesOnce() async throws {
        let (model, studio) = try await window()
        // Long enough for the click under load; the wait below passes it.
        model.consentLifetime = .seconds(2)
        let prompt = holdPrompt(model, studio)
        let answer = ask(model)
        let sheet = try await sheet(model)
        try click(record: true, in: sheet)
        await until("the prompt waits") { prompt.asked() }
        try await Task.sleep(for: .milliseconds(2500))
        #expect(model.consent?.phase == .starting, "the end of the answer time does nothing during the start")
        await model.answerConsent(record: true)

        prompt.give()

        #expect(await answer.value == .started(take: 1, tracks: ["Host"], seconds: 30))
        #expect(studio.transport == .recording(take: 1), "one take")
        await model.stop()
        await model.close()
    }

    /// C3, C6: a window that closes during the microphone prompt gives "closed" and no take.
    @Test func windowChangeDuringPromptRepliesClosed() async throws {
        let (model, studio) = try await window()
        let prompt = holdPrompt(model, studio)
        let answer = ask(model)
        let sheet = try await sheet(model)
        try click(record: true, in: sheet)
        await until("the prompt waits") { prompt.asked() }

        let close = Task { await model.close() }
        await until("the window closes") { model.studio == nil }
        prompt.give()

        #expect(await answer.value == .closed)
        await close.value
        #expect(app.windows.isEmpty)
    }

    /// C6: a close while the sheet waits gives "closed".
    @Test func closeWhileWaitingRepliesClosed() async throws {
        let (model, _) = try await window()
        let answer = ask(model)
        _ = try await sheet(model)
        await model.close()
        #expect(await answer.value == .closed)
    }

    // MARK: C7, C8, C10

    /// C7: each refused start state answers at once, with no sheet.
    @Test func refusedStates() async throws {
        let (model, studio) = try await window()
        #expect(await ask(model, ["x"]).value == .refused(.session(.unknownTrack("x"))))
        #expect(await ask(model, ["t2"]).value == .refused(.noRoute("t2")))
        #expect(await ask(model, ["t1", "t1"]).value == .refused(.channelInUse("t1", "t1")))
        model.alert = .error(.busy)
        #expect(await ask(model).value == .busy(.dialog))
        model.alert = nil
        await until("the alert goes") { model.window?.attachedSheet == nil }

        let first = ask(model)
        _ = try await sheet(model)
        #expect(await ask(model).value == .waits, "a second request")
        await model.answerConsent(record: false)
        #expect(await first.value == .declined)

        model.armed = ["t1"]
        await model.record()
        #expect(studio.transport == .recording(take: 1))
        #expect(await ask(model).value == .busy(.task), "a take runs")
        await model.stop()
        #expect(model.window?.attachedSheet == nil, "no sheet showed")
        await model.close()
    }

    /// C7: a request on one window goes on while another window shows a question.
    @Test func otherWindowSheetDoesNotBlock() async throws {
        let (other, _) = try await window("other")
        other.alert = .error(.busy)
        let (model, _) = try await window()
        let answer = ask(model)
        _ = try await sheet(model)
        await model.answerConsent(record: false)
        #expect(await answer.value == .declined)
        await model.close()
        await other.close()
    }

    /// C8: while a request waits, agent edits are busy and Command-R is off.
    @Test func editWhileAskingIsBusy() async throws {
        let (model, studio) = try await window()
        model.armed = ["t1"]
        #expect(model.canRecord)
        let answer = ask(model)
        _ = try await sheet(model)
        let target = try #require(app.agentTargets().first { $0.studio === studio })
        #expect(target.busy == .asking)
        #expect(!model.canRecord, "Command-R is off")
        await model.answerConsent(record: false)
        #expect(await answer.value == .declined)
        #expect(app.agentTargets().first { $0.studio === studio }?.busy == nil)
        await model.close()
    }

    /// C10: a start error gives the CLI text and the window alert, as Command-R does.
    @Test func startErrorReplies() async throws {
        let (model, studio) = try await window()
        studio.environment.microphoneAccess = { .denied }
        let answer = ask(model)
        try click(record: true, in: try await sheet(model))
        #expect(await answer.value == .refused(.microphoneAccess(.denied)))
        #expect(model.alert == .microphone(.denied))
        #expect(studio.transport == .idle)
        model.alert = nil
        await until("the alert goes") { model.window?.attachedSheet == nil }

        studio.environment.microphoneAccess = { nil }
        try studio.edit { s throws(SessionError) in
            try s.setRoute(.device(uid: "gone", channels: .mono(1)), track: "t1")
        }
        let missing = ask(model)
        try click(record: true, in: try await sheet(model))
        #expect(await missing.value == .refused(.deviceMissing("t1")))
        #expect(model.alert == .error(.deviceMissing("t1")))
        await model.close()
    }

    // MARK: C9

    /// C9: the take stops after the seconds of the request and finalizes; it still runs before them.
    @Test func takeStopsAfterSeconds() async throws {
        let (model, studio) = try await window()
        let answer = ask(model, seconds: 0.5)
        try click(record: true, in: try await sheet(model))
        #expect(await answer.value == .started(take: 1, tracks: ["Host"], seconds: 0.5))
        try await Task.sleep(for: .milliseconds(100))
        #expect(studio.transport == .recording(take: 1), "the take runs at 0.1 s")
        await until("the take stops") { studio.transport == .idle && studio.session.recording == nil }
        // The counting HAL writes no audio, so the take ends with no clip; the finalize ran.
        #expect(studio.lastTake?.take == 1, "take 1 finalized")
        await model.close()
    }

    /// C9: after a Stop of the user, the timer of the request does not stop the next take.
    @Test func userStopKeepsTheNextTake() async throws {
        let (model, studio) = try await window()
        let answer = ask(model, seconds: 1)
        try click(record: true, in: try await sheet(model))
        #expect(await answer.value == .started(take: 1, tracks: ["Host"], seconds: 1))
        await model.stop()
        await until("the take stops") { studio.transport == .idle }
        model.armed = ["t1"]
        await model.record()
        #expect(studio.transport == .recording(take: 2))
        try await Task.sleep(for: .milliseconds(1300))
        #expect(studio.transport == .recording(take: 2), "the old timer did not stop take 2")
        await model.stop()
        await model.close()
    }

    // MARK: C12, C15

    /// C12: in the background the request asks for Dock attention once and cancels it at the end;
    /// in front it asks for none. No window comes to the front.
    @Test(arguments: [false, true]) func attentionWithoutActivation(active: Bool) async throws {
        let (model, _) = try await window()
        var (requests, cancelled) = (0, [Int]())
        model.attention = ConsentAttention(
            isActive: { active },
            request: {
                requests += 1
                return 7
            }, cancel: { cancelled.append($0) })
        let answer = ask(model)
        _ = try await sheet(model)
        #expect(requests == (active ? 0 : 1))
        await model.answerConsent(record: false)
        #expect(await answer.value == .declined)
        #expect(cancelled == (active ? [] : [7]))
        await model.close()
    }

    /// C15: the tracks of the request with a clip after the start frame.
    @Test func recordOverLine() throws {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f", path: "f.wav", layout: .mono, length: 480_000))
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.addTrack("t2", name: "Guest", layout: .mono)
        try session.place(Clip(id: "c1", file: "f", start: 1000, offset: 0, length: 1000), on: "t1")
        try session.place(Clip(id: "c2", file: "f", start: 0, offset: 0, length: 500), on: "t2")
        #expect(recordOverTracks(session, ["t1", "t2"], from: 600) == ["Host"], "c1 after the start, c2 before it")
        #expect(recordOverTracks(session, ["t1", "t2"], from: 2000).isEmpty, "no clip after the start")
        #expect(recordOverTracks(session, ["t2"], from: 499) == ["Guest"], "a clip that ends after the start")
    }
}
