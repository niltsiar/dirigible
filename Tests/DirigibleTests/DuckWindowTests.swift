import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// C17: Tools > Duck Music Under Speech... on a real session window (decision 0060). Tracks t1 to
/// t3 each have a clip of the file f1 at 0..<480 000 (10 s): noise over -40 dBFS, or silence.
@Suite(.serialized) @MainActor struct DuckWindowTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)
    let hal = CountingHAL()

    init() throws { folder = try TemporaryFolder() }

    /// Opens the package with the roles of `roles` and the points of `envelopes` written before the
    /// open, so no undo entry has them.
    func open(
        roles: [TrackID: Track.Role] = ["t1": .dialogue, "t2": .music], envelopes: [ClipID: [Frames: Gain]] = [:],
        silent: Bool = false, device: String = "mic"
    ) async throws -> (SessionWindow, Studio) {
        let url = try await timelinePackage(
            in: folder.url, tracks: 3, seconds: 10, audio: silent, noise: !silent, device: device)
        var session = try Session(contentsOf: url)
        for (track, role) in roles { try session.setRole(role, tracks: [track]) }
        for (clip, points) in envelopes { try session.setEnvelope(points, clip: clip) }
        try session.write(to: url)
        let (model, studio, _, _) = try await openLanes(app, url)
        return (model, studio)
    }

    func sessionBytes(_ studio: Studio) throws -> Data {
        try Data(contentsOf: studio.url.appending(path: "session.xml"))
    }

    /// The item is on with a clip and an idle studio, and off with no clip, during another job,
    /// and during a take. During another job, a press of the item opens no sheet.
    @Test func theItemIsOffWithNoClipDuringAnotherJobAndDuringATake() async throws {
        let (model, studio) = try await open(device: "duo")
        #expect(model.isOn(.duck), "a clip and an idle studio: the item is off")

        let gate = AsyncGate()
        studio.environment.beforeFinalize = { await gate.wait() }
        let leveling = Task { await model.level(.eachClip) }
        await gate.entered()
        #expect(!model.isOn(.duck), "a level runs: the item is on")
        model.run(.duck)
        #expect(model.duckDraft == nil, "a level runs: the item opened the sheet")
        gate.open()
        await leveling.value
        studio.environment.beforeFinalize = {}

        studio.environment = hal.environment
        await model.record()
        #expect(studio.transport == .recording(take: 1))
        await hal.feed(seconds: 0.5)
        #expect(!model.isOn(.duck), "a take runs: the item is on")
        await model.stop()
        await until("the take finalizes") { studio.transport == .idle }
        #expect(model.isOn(.duck), "after the take: the item is off")

        let tracks = studio.session.tracks.map(\.id)
        model.edit(ripple: false) { session throws(SessionError) in try session.clear(.zero..<Frames.limit, on: tracks)
        }
        #expect(studio.session.tracks.allSatisfy { $0.clips.isEmpty }, "the clips stay")
        #expect(!model.isOn(.duck), "no clip: the item is on")
        await model.close()
    }

    /// With no role, the item opens the sheet with both lists empty, and Apply is off with the reason.
    @Test func aSheetWithNoRoleStartsEmpty() async throws {
        let (model, studio) = try await open(roles: [:])
        model.run(.duck)
        let draft = try #require(model.duckDraft, "the item opened no sheet")
        #expect(draft.speech.isEmpty && draft.music.isEmpty, "\(draft)")
        #expect(draft.refusal(in: studio.session) == .noSpeechTrack, "\(draft)")
        await model.close()
    }

    /// The lists come from the roles only: t3 has a route and no role, so no list has it.
    @Test func theSheetPrefillsTheListsFromTheRolesOnly() async throws {
        let (model, studio) = try await open()
        #expect(studio.session.track("t3")?.route != nil && studio.session.track("t3")?.role == nil)
        model.run(.duck)
        let draft = try #require(model.duckDraft, "the item opened no sheet")
        #expect(draft.speech == ["t1"] && draft.music == ["t2"], "\(draft)")
        #expect(draft.refusal(in: studio.session) == nil, "\(draft)")
        var both = draft
        both.music.insert("t1")
        #expect(both.refusal(in: studio.session) == .trackInBothDuckLists("t1"), "\(both)")
        await model.close()
    }

    /// Apply with a selection range ducks the music inside the range only, in one undo step. The
    /// music has a point before the duck, so an undo that leaves a cleared envelope shows.
    @Test func applyDucksTheSelectionRange() async throws {
        let (model, studio) = try await open(envelopes: ["c2": [48_000: try #require(Gain(dB: -3))]])
        let before = studio.session
        model.timeline.marks = Marks(inPoint: 96_000, outPoint: 192_000, tracks: ["t1"])
        model.run(.duck)
        let draft = try #require(model.duckDraft, "the item opened no sheet")

        await model.duck(draft)

        #expect(model.duckDraft == nil && model.alert == nil, "the sheet stays or an alert shows")
        let envelope = studio.session.clip("c2")?.clip.envelope
        #expect(envelope?.gain(at: 144_000) == -16, "the music does not duck in the range")
        #expect(envelope?.gain(at: 400_000) == -3, "the music ducks outside the range")
        let others =
            studio.session.track("t1") == before.track("t1") && studio.session.track("t3") == before.track("t3")
        #expect(others, "a track that is not in the music list changed")
        model.undo()
        let undone = studio.session == before
        #expect(undone && !studio.canUndo, "the duck is not one undo step")
        await model.close()
    }

    /// A selection after the session end: the alert names the range, and the duck changes nothing.
    @Test func aSelectionAfterTheSessionEndShowsTheAlert() async throws {
        let (model, studio) = try await open()
        let (before, bytes) = (studio.session, try sessionBytes(studio))
        model.timeline.marks = Marks(inPoint: 500_000, outPoint: 600_000, tracks: ["t1"])
        model.run(.duck)
        let draft = try #require(model.duckDraft, "the item opened no sheet")

        await model.duck(draft)

        #expect(model.alert == .error(.session(.duckRangePastEnd(500_000..<600_000, end: 480_000))))
        #expect(!model.shown.banners.contains { if case .duckNoSpeech = $0 { true } else { false } })
        let unchanged = studio.session == before
        #expect(unchanged && !studio.canUndo, "the duck changed the session")
        #expect(try sessionBytes(studio) == bytes, "the duck saved")
        await model.close()
    }

    /// A speech file that does not read: track t4 (dialogue) plays the file `gone`, which is not on
    /// disk. The duck uses the speech of t1, and a warning banner names the file.
    @Test func aSpeechFileThatDoesNotReadIsNamedInABanner() async throws {
        let url = try await timelinePackage(in: folder.url, tracks: 3, seconds: 10, noise: true)
        var session = try Session(contentsOf: url)
        try session.addFile(AudioFile(id: "gone", path: "gone.wav", layout: .mono, length: 480_000))
        try session.addTrack("t4", name: "T4", layout: .mono)
        try session.place(Clip(id: "c4", file: "gone", start: 0, offset: 0, length: 480_000), on: "t4")
        try session.setRole(.dialogue, tracks: ["t1", "t4"])
        try session.setRole(.music, tracks: ["t2"])
        try session.write(to: url)
        let (model, studio, _, _) = try await openLanes(app, url)
        model.run(.duck)
        let draft = try #require(model.duckDraft, "the item opened no sheet")

        await model.duck(draft)

        #expect(studio.session.clip("c2")?.clip.envelope.isEmpty == false, "the music does not duck")
        let named = WindowBanner.duckUnread(["gone.wav"], press: 1)
        await until("no banner names gone.wav") { model.shown.banners.contains(named) }
        #expect(named.kind == .warning && named.text == L10n.bannerDuckUnread.format("gone.wav"))
        let silent = WindowBanner.duckNoSpeech(threshold: -40, unread: ["gone.wav"], press: 1).text
        #expect(silent == L10n.errorDuckNoSpeech.format(-40.0) + " " + named.text, "no speech: \(silent)")
        await model.close()
    }

    /// Two failed ducks give two banner keys, so VoiceOver reads the second banner too.
    @Test func eachFailedDuckGetsANewBannerKey() async throws {
        let (model, _) = try await open(silent: true)
        func key() -> String? { model.shown.banners.first { $0.key.hasPrefix("duckNoSpeech") }?.key }
        model.run(.duck)
        await model.duck(try #require(model.duckDraft, "the item opened no sheet"))
        await until("the first banner does not show") { key() != nil }
        let first = key()
        model.run(.duck)
        await model.duck(try #require(model.duckDraft, "the item opened no sheet"))
        await until("the second failed duck has the key of the first") { key() != nil && key() != first }
        await model.close()
    }

    /// Silent speech: the banner gives the reason, and the duck changes nothing and adds no undo step.
    @Test func aDuckWithNoSpeechShowsTheReasonInTheBanner() async throws {
        let (model, studio) = try await open(silent: true)
        let (before, bytes) = (studio.session, try sessionBytes(studio))
        model.run(.duck)
        let draft = try #require(model.duckDraft, "the item opened no sheet")

        await model.duck(draft)

        let reason = WindowBanner.duckNoSpeech(threshold: -40, unread: [], press: 1)
        await until("the banner gives no reason") { model.shown.banners.contains(reason) }
        #expect(reason.kind == .warning && reason.text == L10n.errorDuckNoSpeech.format(-40.0))
        #expect(model.alert == nil, "an alert shows: \(String(describing: model.alert))")
        let unchanged = studio.session == before
        #expect(unchanged && !studio.canUndo, "a duck with no speech changed the session")
        #expect(try sessionBytes(studio) == bytes, "a duck with no speech saved")
        await model.close()
    }
}
