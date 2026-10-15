import DirigibleCore
import Foundation
import Testing
import os

@testable import DirigibleAudio

/// Track fader C6: a fader drag previews its gain in the Player with no edit and no autosave.
extension StudioPlaybackTests {
    /// The gain of `track` in the mix of the running feed.
    func playedGain(_ studio: Studio, track: TrackID = "t1") async -> Double? {
        await studio.play.player?.session.track(track)?.gain.dB
    }

    /// Waits up to 10 s until the played gain of t1 is `dB`.
    func untilPlayed(_ studio: Studio, _ dB: Double, _ message: Comment) async {
        let clock = ContinuousClock()
        let end = clock.now + .seconds(10)
        while await playedGain(studio) != dB {
            guard clock.now < end else {
                Issue.record(message)
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// A studio whose autosaves are counted.
    func countingStudio() async throws -> (Studio, OSAllocatedUnfairLock<Int>) {
        let studio = try await studio()
        let saves = OSAllocatedUnfairLock(initialState: 0)
        let save = studio.environment.saveSession
        studio.environment.saveSession = { [saves] session, lock throws(SessionFileError) in
            saves.withLock { $0 += 1 }
            return try await save(session, lock)
        }
        return (studio, saves)
    }

    @Test func aPreviewReachesThePlayerWithNoEdit() async throws {
        let (studio, saves) = try await countingStudio()
        await studio.perform(.seek(.start))
        await studio.perform(.playStop)
        await untilPlayed(studio, 0, "the play feed runs")

        try studio.previewGain(try #require(Gain(dB: -6)), track: "t1")

        await untilPlayed(studio, -6, "C6: the Player mixes the preview gain")
        #expect(!studio.canUndo, "C6: no undo entry")
        #expect(studio.session.track("t1")?.gain == .zero, "C6: the session keeps its gain")
        try await Task.sleep(for: .milliseconds(300))
        #expect(saves.withLock { $0 } == 0, "C6: no autosave")
        await studio.perform(.playStop)
    }

    /// After a stop the Player object stays for the next play: a preview must not reach it.
    @Test func aPreviewWhenStoppedSendsNothing() async throws {
        let studio = try await studio()
        await studio.perform(.seek(.start))
        await studio.perform(.playStop)
        await untilPlayed(studio, 0, "the play feed runs")
        await studio.perform(.playStop)
        #expect(studio.playback == .stopped)

        try studio.previewGain(try #require(Gain(dB: -6)), track: "t1")

        try await Task.sleep(for: .milliseconds(300))
        let player = try #require(studio.play.player)
        #expect(await player.session.track("t1")?.gain == .zero, "C6: a stopped Player keeps the session gain")
    }

    @Test func aPreviewDuringATakeThrowsBusy() async throws {
        let studio = try await studio()
        studio.transport = .recording(take: 1)
        defer { studio.transport = .idle }
        #expect(throws: StudioError.busy) { try studio.previewGain(.zero, track: "t1") }
    }

    /// A drag with no edit gives the Player the committed gain again.
    @Test func endPreviewSendsTheSessionAgain() async throws {
        let studio = try await studio()
        await studio.perform(.seek(.start))
        await studio.perform(.playStop)
        await untilPlayed(studio, 0, "the play feed runs")
        try studio.previewGain(try #require(Gain(dB: -6)), track: "t1")
        await untilPlayed(studio, -6, "the preview reaches the Player")

        studio.endPreview()

        await untilPlayed(studio, 0, "C6: the committed gain is back")
        await studio.perform(.playStop)
    }

    /// Code gate 1 item 3: an edit during a drag sends the session again; the Player keeps the
    /// dragged gain until `endPreview`.
    @Test func anEditDuringAPreviewKeepsTheDraggedGain() async throws {
        let studio = try await studio()
        await studio.perform(.seek(.start))
        await studio.perform(.playStop)
        await untilPlayed(studio, 0, "the play feed runs")
        try studio.previewGain(try #require(Gain(dB: -6)), track: "t1")
        await untilPlayed(studio, -6, "the preview reaches the Player")

        try studio.edit(ripple: false) { session throws(SessionError) in
            try session.setMarker(Marker(id: "m1", name: "A", position: 0, kind: .marker))
        }
        let clock = ContinuousClock()
        let end = clock.now + .seconds(10)
        while await studio.play.player?.session.markers.isEmpty != false, clock.now < end {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await studio.play.player?.session.markers.isEmpty == false, "the edit reaches the Player")
        #expect(await playedGain(studio) == -6, "code gate 1: the Player keeps the dragged gain")

        studio.endPreview()
        await untilPlayed(studio, 0, "code gate 1: endPreview gives the session gain")
        await studio.perform(.playStop)
    }

    /// Code gate 2: the edit of a fader mouse-up and the end of its preview send the Player one
    /// session, not two.
    @Test func aFaderEditSendsOneSession() async throws {
        let studio = try await studio()
        await studio.perform(.seek(.start))
        await studio.perform(.playStop)
        await untilPlayed(studio, 0, "the play feed runs")
        let gain = try #require(Gain(dB: -6))
        try studio.previewGain(gain, track: "t1")
        let sends = studio.play.revision

        try studio.edit(ripple: false) { session throws(SessionError) in try session.setGain(gain, track: "t1") }
        studio.endPreview()

        #expect(studio.play.revision == sends + 1, "code gate 2: one send")
        await untilPlayed(studio, -6, "the Player has the edit")
        await studio.perform(.playStop)
    }
}
