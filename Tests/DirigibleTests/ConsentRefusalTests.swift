import AppKit
import DirigibleCore
import DirigibleMCP
import Foundation
import Testing
import os

@testable import DirigibleApp
@testable import DirigibleAudio

/// The refusals, the take end, and the attention of an agent record request (decision 0048).
extension ConsentTests {
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
        #expect(await ask(model).value == .busy(.asking), "a second request")
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

    /// A start that a guard refuses after the Record click (here a level runs) gives the agent
    /// the busy cause, not "closed". The window shows the alert of a refused start, and nothing
    /// records.
    @Test func busyStartRepliesBusy() async throws {
        let (model, studio) = try await window()
        let answer = ask(model)
        let sheet = try await sheet(model)
        studio.transport = .leveling

        try click(record: true, in: sheet)

        #expect(await answer.value == .busy(.task))
        #expect(model.alert == .error(.busy) && studio.session.recording == nil && model.consent == nil)
        model.alert = nil
        studio.transport = .idle
        await model.close()
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

    /// C9: the take stops when its length ends, and finalizes. A gate holds the timer of the
    /// length, so no wall clock races the checks.
    @Test func takeStopsAfterSeconds() async throws {
        let (model, studio) = try await window()
        let gate = AsyncGate()
        let length = OSAllocatedUnfairLock<Duration?>(initialState: nil)
        studio.environment.takeLength = { duration in
            length.withLock { $0 = duration }
            await gate.wait()
        }
        let answer = ask(model, seconds: 0.5)
        try click(record: true, in: try await sheet(model))
        #expect(await answer.value == .started(take: 1, tracks: ["Host"], seconds: 0.5))
        let timer = try #require(studio.takeTimer)
        await gate.entered()
        #expect(length.withLock { $0 } == .milliseconds(500))
        #expect(studio.transport == .recording(take: 1), "the take runs until its length ends")

        gate.open()
        await timer.value

        #expect(studio.transport == .idle && studio.session.recording == nil)
        // The counting HAL writes no audio, so the take ends with no clip; the finalize ran.
        #expect(studio.lastTake?.take == 1, "take 1 finalized")
        await model.close()
    }

    /// C9: after a Stop of the user, the timer of the request does not stop the next take. The
    /// gate opens after take 2 starts.
    @Test func userStopKeepsTheNextTake() async throws {
        let (model, studio) = try await window()
        let gate = AsyncGate()
        studio.environment.takeLength = { _ in await gate.wait() }
        let answer = ask(model, seconds: 1)
        try click(record: true, in: try await sheet(model))
        #expect(await answer.value == .started(take: 1, tracks: ["Host"], seconds: 1))
        let timer = try #require(studio.takeTimer)
        await gate.entered()
        await model.stop()
        await until("the take stops") { studio.transport == .idle }
        model.armed = ["t1"]
        await model.record()
        #expect(studio.transport == .recording(take: 2))

        gate.open()
        await timer.value

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

    // MARK: Decision 0050: C10, C11, C15

    /// The free bytes that give `seconds` of a take on one mono track at 48 kHz.
    func freeBytes(forSeconds seconds: Double) -> Int64 { diskMargin + Int64(seconds * 48_000 * 7) }

    /// C10: with room for 60 s, a request of 61 s is refused at once with no sheet; 59 s shows
    /// the sheet.
    @Test func noRoomIsRefused() async throws {
        let (model, studio) = try await window()
        let free = freeBytes(forSeconds: 60)
        studio.environment.freeBytes = { _ in free }

        let refused = await ask(model, seconds: 61).value

        #expect(refused == .noRoom(minutes: 1), "\(refused)")
        #expect(model.consent == nil && model.window?.attachedSheet == nil, "no sheet")
        guard case .result(let text, true) = refused.reply(package: "p.dirigible") else {
            Issue.record("not an error")
            return
        }
        #expect(text == "p.dirigible has room for 1 min of a take on these tracks. Free disk space, then try again.")
        let answer = ask(model, seconds: 59)
        _ = try await sheet(model)
        await model.answerConsent(record: false)
        #expect(await answer.value == .declined)
        await model.close()
    }

    /// C10: a cancel during the free-space read shows no sheet.
    @Test func cancelDuringTheDiskReadShowsNoSheet() async throws {
        let (model, _) = try await window()
        let gate = AsyncGate()
        model.agentRecord.readRecordTime = { _, _ in
            await gate.wait()
            return .seconds(3600)
        }
        let answer = ask(model)
        await gate.entered()
        #expect(model.consent?.phase == .checking, "the request checks the disk")

        answer.cancel()
        gate.open()

        #expect(await answer.value == .ended)
        #expect(model.consent == nil && model.window?.attachedSheet == nil, "no sheet")
        await model.close()
    }

    /// C10: during the free-space read, Command-R stays on and starts the take of the person;
    /// the agent gets the busy reply, and no sheet or grant take.
    @Test func personTakeDuringTheDiskRead() async throws {
        let (model, studio) = try await window()
        let gate = AsyncGate()
        model.agentRecord.readRecordTime = { _, _ in
            await gate.wait()
            return .seconds(3600)
        }
        model.armed = ["t1"]
        let answer = ask(model)
        await gate.entered()
        #expect(model.consent?.phase == .checking)
        let target = try #require(app.agentTargets().first { $0.studio === studio })
        #expect(target.busy == .asking, "agent edits are busy during the check")
        #expect(model.canRecord, "Command-R and the Record menu item stay on")

        await model.record()
        gate.open()

        #expect(studio.transport == .recording(take: 1), "the take of the person starts")
        #expect(await answer.value == .busy(.task))
        #expect(model.consent == nil && model.window?.attachedSheet == nil && model.alert == nil)
        await model.stop()
        await model.close()
    }

    /// C11: 3 requests that showed a sheet in 1 minute; a 4th at 59.9 s is refused, at 60.1 s it
    /// shows the sheet.
    @Test(arguments: [59.9, 60.1]) func fourthAskInAMinuteIsRefused(after: Double) async throws {
        let (model, _) = try await window()
        let start = ContinuousClock.now
        var now = start
        model.agentRecord.now = { now }
        for _ in 0..<3 {
            let answer = ask(model)
            _ = try await sheet(model)
            await model.answerConsent(record: false)
            #expect(await answer.value == .declined)
            await until("the sheet goes") { model.window?.attachedSheet == nil }
        }
        now = start + .seconds(after)

        let answer = ask(model)

        if after < 60 {
            let value = await answer.value
            #expect(value == .tooMany, "\(value)")
            guard case .result(let text, true) = value.reply(package: "p") else {
                Issue.record("not an error")
                return
            }
            #expect(
                text == "Too many record requests: a window takes 3 requests in 1 minute at most. Wait, then ask again."
            )
            #expect(model.consent == nil, "no sheet")
        } else {
            _ = try await sheet(model)
            await model.answerConsent(record: false)
            #expect(await answer.value == .declined)
        }
        await model.close()
    }

    /// C15: a `record` call during a take of the person is busy, and the take goes on.
    @Test func recordDuringPersonTakeIsBusy() async throws {
        let (model, studio) = try await window()
        model.armed = ["t1"]
        await model.record()
        #expect(studio.transport == .recording(take: 1))
        #expect(await ask(model).value == .busy(.task))
        #expect(studio.transport == .recording(take: 1), "the take goes on")
        await model.stop()
        await model.close()
    }
}
