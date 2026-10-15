import AppKit
import DirigibleCore
import DirigibleMCP
import Foundation
import IOKit.pwr_mgt
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
        // A test process has no bundle for the notification center.
        model.notice = AgentTakeNotice(authorize: {}, post: { _, _, _, _ in }, remove: { _ in })
        // The tests of other rules press Record at once; ConsentDelayTests sets the delay.
        model.agentRecord.clickDelay = .zero
        return (model, studio)
    }

    func ask(
        _ model: SessionWindow, _ armed: [TrackID] = ["t1"], seconds: Double = 30, playhead: Frames? = nil,
        connection: AgentConnection? = nil
    ) -> Task<RecordAnswer, Never> {
        let request = RecordRequest(armed: armed, seconds: seconds, playhead: playhead)
        return Task { await model.askRecord(request, agent: agent, connection: connection) }
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

    /// C11: Record refuses the key focus, so Tab and then Space (with Keyboard navigation on)
    /// cannot press it. The test forces the focus, because the system setting is not known.
    @Test func spaceDoesNotRecord() async throws {
        let (model, studio) = try await window()
        let answer = ask(model)
        let sheet = try await sheet(model)
        let record = try #require(sheetButton(cancel: false, in: sheet))
        #expect(!record.acceptsFirstResponder && !record.canBecomeKeyView, "Record refuses the key focus")

        sheet.makeFirstResponder(record)
        press(" ", code: 49, in: sheet)

        #expect(model.consent?.phase == .waiting && studio.transport == .idle, "Space records nothing")
        press("\u{1b}", code: 53, in: sheet)
        let value = await answer.value
        #expect(value == .declined, "\(value)")
        await model.close()
    }

    // MARK: C5, C6

    /// C5: with no answer the sheet closes, nothing records, and the info banner names the agent.
    @Test func expiryClosesTheSheet() async throws {
        let (model, studio) = try await window()
        model.consentWait = { _ in }
        let answer = ask(model)

        #expect(await answer.value == .noAnswer)
        #expect(studio.transport == .idle && model.consent == nil)
        await until("the sheet goes") { model.window?.attachedSheet == nil }
        let text = L10n.bannerConsentExpired.format("Claude Code")
        await until("the banner shows") { model.shown.banners.contains { $0.text == text } }
        await model.close()
    }

    /// Decision 0048: when the agent stops waiting (its bridge closed, or the server stopped),
    /// the sheet closes, nothing records, and the info banner names the agent.
    @Test func cancelledAskEndsTheSheet() async throws {
        let (model, studio) = try await window()
        let answer = ask(model)
        _ = try await sheet(model)

        answer.cancel()

        #expect(await answer.value == .ended)
        #expect(studio.transport == .idle && studio.session.recording == nil && model.consent == nil)
        await until("the sheet goes") { model.window?.attachedSheet == nil }
        let text = L10n.bannerConsentExpired.format("Claude Code")
        await until("the banner shows") { model.shown.banners.contains { $0.text == text } }
        await model.close()
    }

    /// A call that is cancelled before the ask shows no sheet, asks for no attention, and shows
    /// no banner.
    @Test func cancelledBeforeTheAskShowsNothing() async throws {
        let (model, _) = try await window()
        var requests = 0
        model.attention = ConsentAttention(
            isActive: { false },
            request: {
                requests += 1
                return 1
            }, cancel: { _ in })
        let answer = ask(model)

        answer.cancel()

        #expect(await answer.value == .ended)
        #expect(requests == 0 && model.consent == nil && model.consentExpired == nil)
        await model.close()
    }

    /// C5: a click before the end records, and the end after the click does nothing.
    @Test func clickBeforeExpiryRecords() async throws {
        let (model, studio) = try await window()
        let gate = AsyncGate()
        model.consentWait = { _ in await gate.wait() }
        let answer = ask(model)
        let sheet = try await sheet(model)
        let expiry = try #require(model.consent?.expiry)
        try click(record: true, in: sheet)
        #expect(await answer.value == .started(take: 1, tracks: ["Host"], seconds: 30))

        gate.open()
        await expiry.value

        #expect(studio.transport == .recording(take: 1), "the end after the click stops nothing")
        #expect(model.consentExpired == nil)
        await model.stop()
        await model.close()
    }

    /// C5: the activity token lives from the ask to the end, so App Nap does not delay the end.
    /// It is a latency activity: it holds no sleep assertion (probe P3).
    @Test func activityLivesWithTheRequest() async throws {
        let (model, _) = try await window()
        let answer = ask(model)
        let sheet = try await sheet(model)
        let consent = try #require(model.consent)
        #expect(consent.activity != nil)
        #expect(try sleepAssertions(named: ConsentRequest.activityReason).isEmpty, "the system can sleep (probe P3)")
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
        let gate = AsyncGate()
        model.consentWait = { _ in await gate.wait() }
        let prompt = holdPrompt(model, studio)
        let answer = ask(model)
        let sheet = try await sheet(model)
        let expiry = try #require(model.consent?.expiry)
        try click(record: true, in: sheet)
        await until("the prompt waits") { prompt.asked() }
        gate.open()
        await expiry.value
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

    /// C7: the title has no agent name; a line under it quotes the name. With no name, no line.
    /// The no-answer banner uses the same form.
    @Test(arguments: ["Dirigible: click Record to go on", nil]) func nameIsQuotedAndNotInTheTitle(name: String?)
        async throws
    {
        let (model, _) = try await window()
        let request = RecordRequest(armed: ["t1"], seconds: 30, playhead: nil)
        let answer = Task { await model.askRecord(request, agent: AgentName(title: name, clientName: nil)) }
        _ = try await sheet(model)
        // The sheet shows the line for a name only; the on-screen check of S2 reads the texts.
        #expect(model.consent?.agent.name == name)
        await model.answerConsent(record: false)
        #expect(await answer.value == .declined)
        await model.close()
        let english = try stringsTable("en")
        #expect(english[L10n.consentTitle.rawValue] == "An AI agent wants to record", "no name in the title")
        #expect(english[L10n.consentAgentLine.rawValue] == "It says it is “%@”.")
        #expect(
            english[L10n.bannerConsentExpired.rawValue]
                == "An AI agent (it says: “%@”) asked to record. The request ended with no answer.")
    }

    /// C9: a request with an app track shows the line about the call; device tracks only, none.
    @Test(arguments: [true, false]) func appTrackLine(app: Bool) async throws {
        let (model, studio) = try await window()
        if app {
            try studio.edit(ripple: false) { s throws(SessionError) in
                try s.setLayout(.stereo, route: .app(bundleID: "us.zoom.xos"), track: "t1")
            }
        }
        let answer = ask(model)
        _ = try await sheet(model)
        #expect(model.consent?.appTracks == (app ? ["Host"] : []), "the line names the app tracks")
        await model.answerConsent(record: false)
        #expect(await answer.value == .declined)
        await model.close()
        let english = try stringsTable("en")[L10n.consentAppTracks.rawValue]
        #expect(english == "This take records %@. People in the call get no notice from Dirigible.")
    }

    /// The IOPM assertions of this process named `name`.
    func sleepAssertions(named name: String) throws -> [NSDictionary] {
        var byProcess: Unmanaged<CFDictionary>?
        try #require(IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess)
        let processes = try #require(byProcess?.takeRetainedValue() as? [NSNumber: [NSDictionary]])
        return (processes[NSNumber(value: getpid())] ?? []).filter { $0["AssertName"] as? String == name }
    }
}
