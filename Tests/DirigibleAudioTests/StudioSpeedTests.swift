import DirigibleCore
import Foundation
import Testing
import os

@testable import DirigibleAudio

/// Vari-speed criteria V4, V5, V6, V8 (the Studio part), and V13 (run 2026-10-13-preroll-varispeed):
/// the speed of the Studio transport. The Player renders offline (`CaptureEnvironment.test`), so
/// the output latency is 0 and the position is the node position.
@MainActor
struct StudioSpeedTests {
    let package: MixPackage
    let mic = InputDevice(
        uid: "mic", name: "USB Mic", nominalRate: 48_000, availableRates: [48_000...48_000], channelsPerBuffer: [1],
        latency: 0)!

    /// Track `t1` on `mic` channel 1, with clip `c1` of a 440 Hz sine of 8 s at timeline 0.
    init() throws {
        package = try MixPackage()
        let tone = sine(seconds: 8, rate: 48_000, frequency: 440)
        try package.addFile("f1", channels: [tone])
        try package.addTrack("t1", clip: "c1", file: "f1", start: 0, offset: 0, length: Frames(tone.count))
        try package.session.setRoute(Route.device(uid: "mic", channels: .mono(1)), track: "t1")
        try package.session.write(to: package.url)
    }

    func studio(unit: @escaping SpeedUnitLookup = findSpeedUnit) async throws -> Studio {
        let studio = try await Studio.open(package.url)
        studio.environment = .test(TestHAL([mic]))
        studio.environment.speedUnit = unit
        await studio.perform(.seek(.start))
        return studio
    }

    func reading(_ studio: Studio) async throws -> Player.Reading {
        try #require(await studio.play.player?.reading())
    }

    /// V4: the playhead after a change is within one chunk x the speed of the playhead before it,
    /// and the play goes on at the new speed. A change from 1.5 to 2 starts no new play.
    @Test func changeDuringPlayKeepsThePlayhead() async throws {
        let studio = try await studio()
        await studio.perform(.playStop)
        _ = await studio.renderOffline(frames: 24_000)
        let before = try await reading(studio).frame.count
        await studio.changeSpeed(to: .x150)
        let after = studio.playhead.count
        #expect(studio.speed == .x150 && studio.playback == .playing(Shuttle(direction: .forward, rate: .one)))
        #expect(abs(after - before) <= 7_200, "the playhead moved from \(before) to \(after) at the change")
        _ = await studio.renderOffline(frames: 24_000)
        let atOneAndAHalf = try await reading(studio).frame.count
        #expect(abs(atOneAndAHalf - after - 36_000) <= 7_200, "0.5 s at 1.5 moved \(atOneAndAHalf - after)")

        let played = try await reading(studio).played
        await studio.changeSpeed(to: .x200)
        #expect(try await reading(studio).played == played, "a change from 1.5 to 2 started a new play")
        _ = await studio.renderOffline(frames: 24_000)
        let atTwo = try await reading(studio).frame.count
        #expect(abs(atTwo - atOneAndAHalf - 48_000) <= 9_600, "0.5 s at 2 moved \(atTwo - atOneAndAHalf)")
        await studio.perform(.playStop)
    }

    /// V4: stopped, a change sets only the next play.
    @Test func changeWhileStoppedOnlySetsTheNextPlay() async throws {
        let studio = try await studio()
        await studio.changeSpeed(to: .x150)
        #expect(studio.speed == .x150 && studio.playback == .stopped && studio.playhead == 0)
        #expect(studio.play.player == nil, "a change while stopped made a Player")
        await studio.perform(.playStop)
        _ = await studio.renderOffline(frames: 24_000)
        let frame = try await reading(studio).frame.count
        #expect(abs(frame - 36_000) <= 7_200, "0.5 s of the next play moved \(frame)")
        await studio.perform(.playStop)
    }

    /// V5: the first L plays at the speed; the second L (2x) and Shift-L (0.5x) keep the tape rate.
    @Test func shuttleRatesIgnoreTheSpeed() async throws {
        let studio = try await studio()
        await studio.changeSpeed(to: .x150)
        await studio.perform(.forward)
        _ = await studio.renderOffline(frames: 9_600)
        let first = try await reading(studio).frame.count
        #expect(abs(first - 14_400) <= 7_200, "the first L at 1.5 moved \(first)")
        for (command, factor) in [(TransportCommand.forward, 2), (.slowForward, 0.5)] {
            await studio.perform(command)
            // The anchor of the new play. A Player reading before its first render can be ahead of it.
            let start = studio.playhead.count
            _ = await studio.renderOffline(frames: 9_600)
            let moved = try await reading(studio).frame.count - start
            #expect(moved == Int(9_600 * factor), "\(command) moved \(moved), not \(9_600 * factor)")
        }
        #expect(studio.speed == .x150)
        await studio.perform(.playStop)
    }

    /// V6 and V8: during a take a speed change does nothing, and the setting stays after the take.
    @Test func takeKeepsTheSetting() async throws {
        let studio = try await studio()
        await studio.changeSpeed(to: .x150)
        try await studio.startRecording(armed: ["t1"])
        await studio.changeSpeed(to: .x200)
        await studio.changeSpeed(to: .one)
        #expect(studio.speed == .x150, "a speed change acted during the take")
        try await studio.stopRecording()
        #expect(studio.speed == .x150)
    }

    /// Code gate 1 item 5: a Space during the await of a speed change wins. The Player lost its
    /// feed behind the Studio (as after a failed engine start), so the change from 1.5 to 2
    /// needs a new play. The Player queue is held, so the Space comes in the await.
    @Test func aStopDuringASpeedChangeWins() async throws {
        let studio = try await studio()
        await studio.changeSpeed(to: .x150)
        await studio.perform(.playStop)
        let player = try #require(studio.play.player)
        await player.apply(.stop, number: studio.play.feed + 1)
        let hold = DispatchSemaphore(value: 0)
        player.queue.async { hold.wait() }
        let change = Task { await studio.changeSpeed(to: .x200) }
        let stop = Task { await studio.perform(.playStop) }
        await until("the Space took its feed number") { studio.playback == .stopped }
        hold.signal()
        await change.value
        await stop.value
        #expect(studio.playback == .stopped)
        #expect(await !player.reading().running, "the speed change started a play after the Space")
    }

    /// Code gate 1 item 5: with no stop in the await, a change that the unit cannot take plays
    /// again at the new speed.
    @Test func aChangeWithNoFeedPlaysAgain() async throws {
        let studio = try await studio()
        await studio.changeSpeed(to: .x150)
        await studio.perform(.playStop)
        let player = try #require(studio.play.player)
        studio.play.feed += 1
        await player.apply(.stop, number: studio.play.feed)
        await studio.changeSpeed(to: .x200)
        #expect(await player.reading().running, "no new play after the change")
        await studio.perform(.playStop)
    }

    /// Code gate 2 item 5: the Studio looks the unit up once, not at each read of the chrome.
    @Test func theUnitLookupRunsOnce() async throws {
        let lookups = OSAllocatedUnfairLock(initialState: 0)
        let studio = try await studio(unit: {
            lookups.withLock { $0 += 1 }
            return findSpeedUnit()
        })
        for _ in 0..<5 { _ = studio.canChangeSpeed }
        #expect(lookups.withLock { $0 } == 1, "\(lookups.withLock { $0 }) lookups for 5 reads")
    }

    /// V13: with no unit, the speed stays 1 and the control is off.
    @Test func unitFailureKeepsOne() async throws {
        let studio = try await studio(unit: { nil })
        #expect(!studio.canChangeSpeed)
        await studio.changeSpeed(to: .x150)
        #expect(studio.speed == .one)
    }
}
