import AppKit
import CoreAudio
import DirigibleCore
import Foundation
import Testing
import os

@testable import DirigibleApp
@testable import DirigibleAudio

/// Input Levels with an armed app track in a real window (decisions 0015 and 0029): the meter with
/// no microphone, the come back to Dirigible, and the **No sound from** announcement. The fake tap
/// counts its creates; no test makes a real tap.
extension MonitorWindowTests {
    nonisolated static let zoom = "us.zoom.xos"

    /// The texts that the window announced.
    final class Announced {
        var texts: [String] = []
    }

    /// A window on a package with `host` on channel 1 of `duo` and `guest` (mono) on Zoom. Zoom
    /// runs and plays; each tap create adds 1 to `taps`.
    func appWindow(_ taps: OSAllocatedUnfairLock<Int>) async throws -> (SessionWindow, Studio) {
        let package = folder.url.appending(path: "app.dirigible")
        try await Task.detached {
            var session = Session(sampleRate: 48_000)
            try session.addTrack("host", name: "Host", layout: .mono)
            try session.addTrack("guest", name: "Guest", layout: .mono)
            try session.setRoute(Route.device(uid: "duo", channels: .mono(1)), track: "host")
            try session.setRoute(.app(bundleID: Self.zoom), track: "guest")
            try session.write(to: package)
        }.value
        let window = await app.open(package)
        let studio = try #require(await window.opened() ? window.studio : nil)
        var environment = hal.environment
        let device = try #require(
            InputDevice(
                uid: "app:\(Self.zoom)", name: Self.zoom, nominalRate: 48_000, availableRates: [48_000...48_000],
                channelsPerBuffer: [1], latency: 0))
        let found = AppFound(
            key: AppKey(processes: [41], output: "BuiltInSpeakerDevice"), output: "BuiltInSpeakerDevice",
            device: device, playing: true)
        environment.hal.lookUpApp = { bundleID, _ in bundleID == Self.zoom ? found : nil }
        environment.hal.makeTap = { found, _ in
            let id = taps.withLock {
                $0 += 1
                return $0
            }
            return (AudioObjectID(100 + id), found.device, { true })
        }
        studio.environment = environment
        return (window, studio)
    }

    /// Turns Input Levels on with only `guest` armed, and waits for its first tap.
    func meterGuest(_ window: SessionWindow, _ studio: Studio, _ taps: OSAllocatedUnfairLock<Int>) async {
        window.armed = ["guest"]
        window.monitoring = true
        await until("no meter of the app track") {
            studio.liveTracks["guest"]?.state == .monitoring && taps.withLock { $0 } >= 1
        }
        await studio.monitorWriter("app:\(Self.zoom)")?.started()
    }

    // MARK: C12

    @Test func inputLevelsMetersAnAppTrackWithNoMicrophone() async throws {
        let taps = OSAllocatedUnfairLock(initialState: 0)
        let (window, studio) = try await appWindow(taps)
        studio.environment.microphoneAccess = { .denied }

        await meterGuest(window, studio, taps)
        #expect(window.monitoring)
        #expect(window.alert == nil)

        // The control: a device track in the request shows the microphone alert.
        window.armed = ["guest", "host"]
        await until("no microphone alert") { window.alert == .microphone(.denied) }
        #expect(!window.monitoring)
    }

    // MARK: C4b (c)

    @Test func comingBackRetapsASilentAppTrack() async throws {
        let taps = OSAllocatedUnfairLock(initialState: 0)
        let (window, studio) = try await appWindow(taps)
        await meterGuest(window, studio, taps)
        let writer = try #require(studio.monitorWriter("app:\(Self.zoom)"))

        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await writer.started()
        #expect(taps.withLock { $0 } == 1, "a come back taps a track with no warning again")
        studio.liveTracks["guest"]?.state = .noSound
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await until("the come back does not tap the silent track again") { taps.withLock { $0 } == 2 }
    }

    // MARK: C20 (a)

    @Test func noSoundFromIsAnnounced() async throws {
        let taps = OSAllocatedUnfairLock(initialState: 0)
        let (window, studio) = try await appWindow(taps)
        let announced = Announced()
        try #require(window.chrome).announce = { text, _ in announced.texts.append(text) }
        // Only the test writes `liveTracks`: a running writer reports peak 0 at each drain.
        func meterQuietGuest() async {
            await meterGuest(window, studio, taps)
            await studio.monitorWriter("app:\(Self.zoom)")?.finish()
        }
        await meterQuietGuest()
        func set(_ state: LiveTrack.State, peak: Float = 0) {
            studio.liveTracks["guest"] = LiveTrack(state: state, droppedFrames: 0, peak: peak)
        }
        func shows(_ noSound: Bool) async {
            await until("the chrome does not follow the state") { window.shown.noSound.contains("guest") == noSound }
        }
        func toggle() async {
            window.monitoring = false
            await until("Input Levels off keeps the meter") { studio.liveTracks["guest"] == nil }
            await meterQuietGuest()
        }

        set(.noSound)
        await shows(true)
        #expect(announced.texts == [HeaderStateText.noSound(window.appName(Self.zoom)).full])
        set(.monitoring)
        await shows(false)
        set(.noSound)
        await shows(true)
        #expect(announced.texts.count == 1, "a rearm with no sound announces again")
        set(.monitoring, peak: 0.5)
        await shows(false)
        set(.noSound)
        await shows(true)
        #expect(announced.texts.count == 2, "no announcement after a sound")
        await toggle()
        set(.noSound)
        await shows(true)
        #expect(announced.texts.count == 3, "no announcement after the toggle")
        set(.monitoring)
        await shows(false)
        await toggle()
        set(.noSound)
        await shows(true)
        #expect(announced.texts.count == 4, "no announcement after a toggle while the track monitors")

        await window.record()
        await until("no take") { window.canStop && studio.liveTracks["guest"]?.state == .recording }
        set(.noSound)
        await shows(true)
        #expect(announced.texts.count == 5, "no announcement in the take")
        await window.stop()
        await until("no monitor after the take") { !window.canStop && studio.liveTracks["guest"]?.state == .monitoring }
        set(.noSound)
        await shows(true)
        #expect(announced.texts.count == 6, "no announcement after the take")
    }
}
