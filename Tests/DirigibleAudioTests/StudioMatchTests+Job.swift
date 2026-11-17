import DirigibleCore
import Foundation
import Testing
import os

@testable import DirigibleAudio

/// Criterion C11 of decision 0074: the job rules of `Studio.matchVoice` and the amount preview.
extension StudioMatchTests {
    /// A second match with the same reference gives the same curve: the measure reads the clips
    /// with no match stage, so matches do not stack.
    @Test func secondMatchDoesNotStack() async throws {
        let fixture = try await MatchFixture(
            reference: repeated(Self.flat, seconds: 20), targets: [repeated(Self.rising, seconds: 20)])
        try await fixture.matchVoice(amount: 100)
        let first = try fixture.match()
        try await fixture.matchVoice()
        let second = try fixture.match()
        let drift = zip(second.curve.decibels, first.curve.decibels).map { abs($0 - $1) }
        #expect(drift.max()! <= 0.01, "the second match stacked: \(drift)")
        #expect(first.curve.decibels.map(abs).max()! >= 3, "the fixture has a curve")
    }

    /// The banner Cancel during the read throws `.matchCancelled`; nothing changes.
    @Test func cancelChangesNothing() async throws {
        let fixture = try await MatchFixture(
            reference: repeated(Self.flat, seconds: 20), targets: [repeated(Self.rising, seconds: 20)])
        let studio = fixture.studio
        let gate = AsyncGate()
        studio.environment.beforeFinalize = { await gate.wait() }
        let file = fixture.package.url.appending(path: "session.xml")
        let before = (studio.session, try Data(contentsOf: file))
        let matching = Task { try await fixture.matchVoice() }
        await gate.entered()
        #expect(studio.transport == .matching, "match hold: \(studio.transport)")
        studio.cancelReadJob()
        gate.open()
        let result = await matching.result
        #expect(throws: StudioError.matchCancelled) { try result.get() }
        #expect(studio.session == before.0 && !studio.canUndo, "a cancelled match changed the session")
        #expect(try Data(contentsOf: file) == before.1, "a cancelled match saved")
        #expect(studio.transport == .idle)
    }

    /// A match or an amount preview during a take throws `busy`, changes nothing, and the take
    /// goes on.
    @Test func busyDuringTake() async throws {
        let fixture = try await MatchFixture(
            reference: repeated(Self.flat, seconds: 20), targets: [repeated(Self.rising, seconds: 20)]
        ) { session in
            try session.setRoute(Route.device(uid: "mic", channels: .mono(1)), track: "t1")
        }
        let studio = fixture.studio
        studio.environment = .test(TestHAL([StopLevelTests.mic]))
        _ = try await studio.startTake(
            armed: ["t1"], devices: [StopLevelTests.mic], playhead: 0, hostTimeNanos: takeStart)
        let before = studio.session
        await #expect(throws: StudioError.busy) { try await fixture.matchVoice() }
        #expect(throws: StudioError.busy) { try studio.previewMatchAmount(VoiceMatch.defaultAmount, track: "t1") }
        #expect(studio.session == before && studio.transport == .recording(take: 1), "\(studio.transport)")
        try await studio.stopRecording()
    }

    /// A drag step of the amount plays in the Player with no edit, no undo entry, and no save;
    /// `endPreview` gives the Player the stored amount again. A drag that ends at its start value
    /// makes no entry.
    @Test func amountPreviewMakesNoEntry() async throws {
        let fixture = try await MatchFixture(
            reference: repeated(Self.flat, seconds: 20), targets: [repeated(Self.rising, seconds: 20)])
        let studio = fixture.studio
        try await fixture.matchVoice()
        studio.environment = .test(TestHAL([StopLevelTests.mic]))
        let saves = OSAllocatedUnfairLock(initialState: 0)
        let save = studio.environment.saveSession
        studio.environment.saveSession = { [saves] session, lock throws(SessionFileError) in
            saves.withLock { $0 += 1 }
            return try await save(session, lock)
        }
        let revision = studio.sessionRevision
        await studio.perform(.seek(.start))
        await studio.perform(.playStop)
        await Self.untilPlayed(studio, 75, "the play feed has the match")

        try studio.previewMatchAmount(VoiceMatch.Amount(40)!, track: "t1")

        await Self.untilPlayed(studio, 40, "the Player mixes the preview amount")
        #expect(studio.sessionRevision == revision, "a preview made an edit")
        #expect(try fixture.match().amount == VoiceMatch.defaultAmount, "the session keeps its amount")
        try await Task.sleep(for: .milliseconds(300))
        #expect(saves.withLock { $0 } == 0, "a preview saved")
        studio.endPreview()
        await Self.untilPlayed(studio, 75, "endPreview gives the stored amount")
        try studio.setMatchAmount(VoiceMatch.defaultAmount, tracks: ["t1"], agent: nil)
        #expect(studio.sessionRevision == revision, "a drag back to its start made an entry")
        #expect(throws: StudioError.session(.noMatch("ref"))) {
            try studio.previewMatchAmount(VoiceMatch.defaultAmount, track: "ref")
        }
        await studio.perform(.playStop)
    }

    /// Waits up to 10 s until the Player plays the match of t1 at `percent`.
    static func untilPlayed(_ studio: Studio, _ percent: Int, _ message: Comment) async {
        let clock = ContinuousClock()
        let end = clock.now + .seconds(10)
        while await studio.play.player?.session.track("t1")?.match?.amount.percent != percent {
            guard clock.now < end else {
                Issue.record(message)
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
