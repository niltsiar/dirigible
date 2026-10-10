import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Track > Monitor Track (decision 0044, run 1a): the window state, the menu item rules, and the
/// quiet text, with real windows, real packages, and the counting HAL.
@MainActor struct TrackMonitorMenuTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)
    let hal = CountingHAL()

    init() throws { folder = try TemporaryFolder() }

    /// `t1` on channel 1 of `duo`, `t2` on channel 2, `t3` on an app, and `t4` with no route.
    func package() async throws -> URL {
        let package = folder.url.appending(path: "listen.dirigible")
        try await Task.detached {
            var session = Session(sampleRate: 48_000)
            try session.addTrack("t1", name: "Host", layout: .mono)
            try session.addTrack("t2", name: "Guest", layout: .mono)
            try session.addTrack("t3", name: "Call", layout: .mono)
            try session.addTrack("t4", name: "Spare", layout: .mono)
            try session.setRoute(Route.device(uid: "duo", channels: .mono(1)), track: "t1")
            try session.setRoute(Route.device(uid: "duo", channels: .mono(2)), track: "t2")
            try session.setRoute(.app(bundleID: "us.zoom.xos"), track: "t3")
            try session.write(to: package)
        }.value
        return package
    }

    /// A window on `package` with the counting HAL.
    func window(_ package: URL) async throws -> (SessionWindow, Studio) {
        let window = await app.open(package)
        let studio = try #require(await window.opened() ? window.studio : nil)
        studio.environment = hal.environment
        return (window, studio)
    }

    /// A click on the header of `track`: it is the only selected track.
    func select(_ track: TrackID, in window: SessionWindow, _ studio: Studio) {
        window.timeline.selection = Selection.none.clickingHeader(
            track, command: false, shift: false, in: studio.session)
    }

    // MARK: A14 and A15

    @Test func aClickMonitorsAnArmedTrack() async throws {
        let (window, studio) = try await window(try await package())
        #expect(window.armed.contains("t1") && !window.monitoring, "t1 is armed, Monitor Inputs is off")
        select("t1", in: window, studio)
        #expect(window.canListen && !window.listensSelection)

        window.toggleListen()
        #expect(window.listensSelection, "A14: the item is on")
        await until("A14: the device plays and the meter shows") {
            studio.listeners["duo"] != nil && studio.liveTracks["t1"]?.state == .monitoring
        }
        #expect(studio.liveTracks["t2"] == nil, "only the listened track meters")

        window.toggleListen()
        await until("the second click turns the monitor off") { studio.listeners.isEmpty && hal.isFree }
        await window.close()
    }

    @Test func aClickMonitorsATrackThatIsNotArmed() async throws {
        let (window, studio) = try await window(try await package())
        window.armed = []
        select("t2", in: window, studio)
        window.toggleListen()
        await until("A15: a track that is not armed plays and meters") {
            studio.listeners["duo"] != nil && studio.liveTracks["t2"]?.state == .monitoring
        }
        await window.close()
    }

    // MARK: A16 and A23

    /// Control in the same test: a device track enables the item.
    @Test func anAppTrackHasNoMonitor() async throws {
        let (window, studio) = try await window(try await package())
        select("t3", in: window, studio)
        #expect(!window.canListen, "A16: an app track disables the item")
        window.toggleListen()
        select("t4", in: window, studio)
        #expect(!window.canListen, "A16: a track with no route disables the item")
        window.toggleListen()
        #expect(window.listened.isEmpty, "a disabled item changes nothing")
        select("t1", in: window, studio)
        #expect(window.canListen, "a device track enables the item")
        await window.close()
    }

    @Test func noSelectionDisablesTheItem() async throws {
        let (window, studio) = try await window(try await package())
        window.timeline.selection = .none
        #expect(!window.canListen, "A23: no selected track disables the item")
        select("t1", in: window, studio)
        #expect(window.canListen)
        await window.close()
    }

    // MARK: A20

    @Test func noAccessTurnsTheMonitorOff() async throws {
        let (window, studio) = try await window(try await package())
        studio.environment.microphoneAccess = { .denied }
        select("t1", in: window, studio)
        window.toggleListen()
        await until("A20: the access alert shows") { window.alert == .microphone(.denied) }
        #expect(window.listened.isEmpty && !window.listensSelection, "A20: the item turns off")
        #expect(studio.listeners.isEmpty && hal.isFree, "A20: no device is held")
        await window.close()
    }

    // MARK: A25 and A24

    /// The state is not in the session, so a new window has every monitor off.
    @Test func theMonitorIsOffAtOpen() async throws {
        let (window, studio) = try await window(try await package())
        #expect(window.listened.isEmpty && studio.listeners.isEmpty, "A25: off at open")
        select("t1", in: window, studio)
        window.toggleListen()
        await until("the monitor plays") { studio.listeners["duo"] != nil }
        await window.close()
        #expect(window.listened.isEmpty && studio.listeners.isEmpty, "A24: the close turns the monitor off")
    }

    // MARK: The quiet text

    @Test func aQuietMonitorShowsItsText() async throws {
        let (window, studio) = try await window(try await package())
        studio.environment.listenOutput = .offline(startFails: true)
        select("t1", in: window, studio)
        window.toggleListen()
        await until("the failed output start is quiet") { studio.quietListens == ["t1"] }
        #expect(listenQuietText(live: studio.liveTracks["t1"], quiet: true) == L10n.trackListenQuiet.text)
        let lost = LiveTrack(state: .deviceLost, droppedFrames: 0, peak: 0)
        #expect(listenQuietText(live: lost, quiet: true) == nil, "a meter fault shows first")
        #expect(listenQuietText(live: nil, quiet: false) == nil, "a track that plays has no text")
        await window.close()
    }
}
