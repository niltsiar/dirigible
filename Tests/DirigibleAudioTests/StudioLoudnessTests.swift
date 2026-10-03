import DirigibleCore
import Foundation
import Observation
import Testing
import os

@testable import DirigibleAudio

/// Run 9b criterion 12: `Studio.loudness` holds the values of the heard frame. It has M and S
/// only while a 1x forward play runs; every stop holds I and TP. No view observes it.
@MainActor
struct StudioLoudnessTests {
    let package: MixPackage
    let mic = InputDevice(
        uid: "mic", name: "USB Mic", nominalRate: 48_000, availableRates: [48_000...48_000], channelsPerBuffer: [2],
        latency: 0)!

    /// Track `t1` (stereo, on `mic` channels 1 and 2) with 5 s at -30 dBFS, then 5 s at -20 dBFS.
    init() throws {
        package = try MixPackage()
        let signal = tone([(5, -30), (5, -20)])
        try package.addFile("f1", channels: signal)
        try package.addTrack("t1", layout: .stereo, clip: "c1", file: "f1", start: 0, offset: 0, length: 480_000)
        try package.session.setRoute(Route.device(uid: "mic", channels: .stereo(1, 2)), track: "t1")
        try package.session.write(to: package.url)
    }

    func studio() async throws -> Studio {
        let studio = try await Studio.open(package.url)
        studio.environment = .test(TestHAL([mic]))
        return studio
    }

    func expectHeld(_ studio: Studio, _ label: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let values = studio.loudness
        #expect(
            values.momentary == nil && values.shortTerm == nil && values.integrated != nil,
            "\(label): \(values)", sourceLocation: sourceLocation)
    }

    /// A meter fed at render time reads about -29.0 at the stop: 3 unheard blocks at -20 dBFS.
    @Test func stopHoldsIntegratedAndNothingObserves() async throws {
        let studio = try await studio()
        await studio.perform(.seek(.start))
        await studio.perform(.playStop)
        let changed = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = studio.loudness
            _ = studio.session
        } onChange: {
            changed.withLock { $0 = true }
        }
        _ = await studio.renderOffline(frames: 96_000)
        // A hang guard, as for the playhead poll of StudioPlaybackFaultTests.
        await until(limit: .seconds(36), "the poll did not write the loudness") { studio.loudness.seconds >= 1.9 }
        #expect(studio.loudness.momentary != nil, "M during the play")
        #expect(!changed.withLock { $0 }, "an observer saw a change during the play")

        _ = await studio.renderOffline(frames: 144_000)
        await studio.perform(.playStop)
        expectHeld(studio, "the stop")
        expectLUFS(studio.loudness.integrated, -30, "I at the stop at 5.0 s")
    }

    @Test func theSessionEndHoldsIntegrated() async throws {
        let studio = try await studio()
        await studio.perform(.seek(.frame(384_000)))
        await studio.perform(.playStop)
        _ = await studio.renderOffline(frames: 96_000)
        await until(limit: .seconds(19), "the play did not end") { studio.playback == .stopped }
        expectHeld(studio, "the session end")
    }

    @Test func anOutputChangeHoldsIntegrated() async throws {
        let studio = try await studio()
        await studio.perform(.seek(.start))
        await studio.perform(.playStop)
        _ = await studio.renderOffline(frames: 48_000)
        await until(limit: .seconds(36), "the poll did not write M") { studio.loudness.momentary != nil }
        await studio.play.player?.postConfigurationChange()
        await until(limit: .seconds(17), "the output change did not stop the play") { studio.playback == .stopped }
        expectHeld(studio, "the output change")
    }

    @Test func recordDuringAPlayHoldsIntegrated() async throws {
        let studio = try await studio()
        await studio.perform(.seek(.start))
        await studio.perform(.playStop)
        _ = await studio.renderOffline(frames: 48_000)
        await until(limit: .seconds(36), "the poll did not write M") { studio.loudness.momentary != nil }
        try await studio.startRecording(armed: ["t1"])
        expectHeld(studio, "Record during a play")
        try await studio.stopRecording()
    }
}
