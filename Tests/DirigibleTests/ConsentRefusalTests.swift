import AppKit
import DirigibleCore
import DirigibleMCP
import Foundation
import Testing

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
