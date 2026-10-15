import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The Apps section of the track route menu (A15), the app name in the header (A7, A9), and
/// the macOS floor (A14), with an injected app list and real windows.
@Suite(.serialized) @MainActor struct AppRouteMenuTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)
    let hal = CountingHAL()
    nonisolated static let zoom = RunningApp(
        bundleID: "us.zoom.xos", name: "zoom.us", path: "/Applications/zoom.us.app", playing: true, processes: [41])
    nonisolated static let chrome = RunningApp(
        bundleID: "com.google.Chrome", name: "Google Chrome", path: "/Applications/Google Chrome.app",
        playing: false, processes: [42])

    init() throws { folder = try TemporaryFolder() }

    /// `t1` (mono) on channel 1 of `duo`, and `t2` (stereo) with no route.
    func window() async throws -> (SessionWindow, Studio) {
        let url = folder.url.appending(path: "apps.dirigible")
        try await Task.detached {
            var session = Session(sampleRate: 48_000)
            try session.addTrack("t1", name: "Host", layout: .mono)
            try session.addTrack("t2", name: "Guest", layout: .stereo)
            try session.setRoute(.device(uid: "duo", channels: .mono(1)), track: "t1")
            try session.write(to: url)
        }.value
        let model = await app.open(url)
        let studio = try #require(await model.opened() ? model.studio : nil)
        try await fixFreeSpace(model)
        studio.environment = hal.environment
        model.readApps = { [Self.chrome, Self.zoom] }
        return (model, studio)
    }

    /// A15: one item for each app, in the order of the list; A14: with no process taps, one
    /// disabled item.
    @Test func theAppsSectionListsEachAppOrTheFloor() {
        #expect(
            appMenuItems([Self.chrome, Self.zoom], tapsAvailable: true) == [
                .app(bundleID: "com.google.Chrome", name: "Google Chrome"),
                .app(bundleID: "us.zoom.xos", name: "zoom.us"),
            ], "an item for each app")
        #expect(appMenuItems([Self.zoom], tapsAvailable: false) == [.unavailable], "the macOS floor")
        #expect(appMenuItems([], tapsAvailable: true).isEmpty)
    }

    /// The app list is read off the main actor, and the window keeps each name.
    @Test func theWindowReadsTheAppsOffTheMainActor() async throws {
        let (model, _) = try await window()
        model.readApps = {
            dispatchPrecondition(condition: .notOnQueue(.main))
            return [Self.zoom]
        }
        model.refreshApps()
        await until("no apps") { model.apps == [Self.zoom] }
        #expect(model.appName("us.zoom.xos") == "zoom.us", "the name of a listed app")
        model.readApps = { [] }
        model.refreshApps()
        await until("the list did not change") { model.apps.isEmpty }
        #expect(model.appName("us.zoom.xos") == "zoom.us", "the name stays after the app quits")
        #expect(model.appName("com.example.none") == "com.example.none", "else the bundle ID")
    }

    /// A routed app that does not run gets the name of its bundle, read off the main actor.
    @Test func aRoutedAppThatDoesNotRunShowsItsBundleName() async throws {
        let (model, _) = try await window()
        model.setAppRoute("com.example.call", track: "t2")
        model.readApps = { [] }
        model.readAppName = { id in
            dispatchPrecondition(condition: .notOnQueue(.main))
            return id == "com.example.call" ? "Example Call" : id
        }
        model.refreshApps()
        await until("no name") { model.appName("com.example.call") == "Example Call" }
    }

    /// A pick with no take: the app route in one undo entry, and the track is armed. The stereo
    /// track keeps its layout (a stereo mixdown).
    @Test func aPickSetsTheAppRouteInOneUndoEntry() async throws {
        let (model, studio) = try await window()
        model.setAppRoute("us.zoom.xos", track: "t2")
        #expect(studio.session.track("t2")?.route == .app(bundleID: "us.zoom.xos"), "the app route")
        #expect(studio.session.track("t2")?.layout == .stereo)
        #expect(model.armed.contains("t2"), "armed")
        try studio.undo()
        #expect(studio.session.track("t2")?.route == nil, "one undo entry")
    }

    /// A pick with a focused name field applies, and the typed name stays.
    @Test func aPickWithATypedNameApplies() async throws {
        let (model, studio) = try await window()
        model.drafts["t2"] = "Remote"
        model.setAppRoute("us.zoom.xos", track: "t2")
        #expect(studio.session.track("t2")?.route == .app(bundleID: "us.zoom.xos"))
        #expect(model.drafts["t2"] == "Remote", "the typed name stays")
    }

    /// A pick during a take changes nothing (the menu items are disabled, as for a device).
    @Test func aPickDuringATakeChangesNothing() async throws {
        let (model, studio) = try await window()
        model.armed = ["t1"]
        await model.record()
        #expect(studio.transport == .recording(take: 1))
        model.setAppRoute("us.zoom.xos", track: "t2")
        #expect(studio.session.track("t2")?.route == nil, "no change during a take")
        #expect(!model.canEdit, "the menu is disabled")
        await model.stop()
    }

    // MARK: B1c, Add Call Tracks

    nonisolated static let duo = InputDevice(
        uid: "duo", name: "Duo", nominalRate: 48_000, availableRates: [48_000...48_000], channelsPerBuffer: [2],
        latency: 0)!

    /// The running apps by name, a divider, and No App; one disabled item with no app or no taps.
    @Test func callMenuListsAppsThenNoApp() {
        #expect(
            callMenuItems([Self.chrome, Self.zoom], tapsAvailable: true) == [
                .app(bundleID: "com.google.Chrome", name: "Google Chrome"),
                .app(bundleID: "us.zoom.xos", name: "zoom.us"), .divider, .noApp,
            ], "an item for each app")
        #expect(callMenuItems([], tapsAvailable: true) == [.noApps, .divider, .noApp], "no running app")
        #expect(callMenuItems([Self.zoom], tapsAvailable: false) == [.unavailable, .divider, .noApp], "the floor")
    }

    /// `window()` with `duo` in the device list and `input` as the default input device.
    func callWindow(input: String? = "duo") async throws -> (SessionWindow, Studio) {
        let (model, studio) = try await window()
        let list = DeviceList(read: { [Self.duo] }, defaults: { AudioDefaults(inputUID: input) })
        model.deviceList = list
        await until("no device read") { list.reads >= 1 }
        return (model, studio)
    }

    /// Host on channel 1 of the default input and Guest on the app go after the tracks, both armed,
    /// in one undo entry; also in a session with no track.
    @Test func addCallTracksIsOneUndoEntry() async throws {
        let (model, studio) = try await callWindow()
        model.armed = []
        model.addCallTracks(app: "us.zoom.xos")
        let tracks = studio.session.tracks
        try #require(tracks.count == 4, "not two new tracks after t1 and t2")
        let (host, guest) = (tracks[2], tracks[3])
        #expect(host.name == L10n.trackNameHost.text && guest.name == L10n.trackNameGuest.text)
        #expect(host.layout == .mono && guest.layout == .mono)
        #expect(host.route == .device(uid: "duo", channels: .mono(1)), "Host on the default input")
        #expect(guest.route == .app(bundleID: "us.zoom.xos"), "Guest on the app")
        #expect(model.armed == [host.id, guest.id], "both armed")
        try studio.undo()
        #expect(studio.session.tracks.map(\.id) == ["t1", "t2"], "one undo entry")

        try studio.edit(ripple: false) { s throws(SessionError) in
            try s.removeTrack("t1")
            try s.removeTrack("t2")
        }
        model.addCallTracks(app: nil)
        #expect(studio.session.tracks.count == 2, "two tracks in an empty session")
        #expect(studio.session.tracks.last?.route == nil, "No App: Guest has no route")
        try studio.undo()
        #expect(studio.session.tracks.isEmpty, "one undo entry")
    }

    /// During a take the call changes nothing, and the menu is disabled.
    @Test func addCallTracksDuringATakeChangesNothing() async throws {
        let (model, studio) = try await callWindow()
        model.armed = ["t1"]
        await model.record()
        #expect(studio.transport == .recording(take: 1))
        model.addCallTracks(app: "us.zoom.xos")
        #expect(studio.session.tracks.count == 2, "no change during a take")
        #expect(!model.canEdit, "the menu is disabled")
        await model.stop()
    }

    /// A pending take adds the tracks, as Add Track does. The take keeps t1 on channel 1 of duo,
    /// so Host keeps its route and is not armed.
    @Test func addCallTracksWithAPendingTakeAdds() async throws {
        let (model, studio) = try await callWindow()
        model.armed = ["t1"]
        let clips = model.url.appending(path: clipsFolderName)
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        await model.record()
        await hal.feed(seconds: 0.5)
        chmod(clips.path, 0o500)
        await model.stop()
        await until("the finalize fails") { studio.transport == .idle }
        chmod(clips.path, 0o755)
        try #require(studio.pendingTake != nil)

        model.addCallTracks(app: "us.zoom.xos")
        let tracks = studio.session.tracks
        try #require(tracks.count == 4, "no tracks with a pending take")
        #expect(tracks[2].route == .device(uid: "duo", channels: .mono(1)))
        #expect(!model.armed.contains(tracks[2].id) && model.armed.contains(tracks[3].id))
        await model.close()
    }

    /// No default input, or one that is not in the device list: Host has no route and no arm.
    @Test(arguments: [nil, "gone"]) func addCallTracksWithNoDefaultInputLeavesHostUnrouted(input: String?) async throws
    {
        let (model, studio) = try await callWindow(input: input)
        model.addCallTracks(app: "us.zoom.xos")
        let tracks = studio.session.tracks
        try #require(tracks.count == 4)
        #expect(tracks[2].route == nil, "Host has no route")
        #expect(!model.armed.contains(tracks[2].id))
        #expect(tracks[3].route == .app(bundleID: "us.zoom.xos") && model.armed.contains(tracks[3].id), "control")
    }

    /// The focus in a name field with a typed name: the name is saved first, as Record does.
    @Test func addCallTracksWithATypedNameApplies() async throws {
        let (model, studio) = try await callWindow()
        model.drafts["t2"] = "Remote"
        model.addCallTracks(app: "us.zoom.xos")
        #expect(studio.session.track("t2")?.name == "Remote", "the typed name is saved")
        #expect(studio.session.tracks.count == 4, "the tracks are added")
    }

    /// An armed track that takes a channel of a new track blocks its arm; the route stays, and
    /// Record finds no channel in use. Control: an armed mono(2) on duo lets Host arm.
    @Test(arguments: [
        (Route.device(uid: "duo", channels: .mono(1)), false, true),
        (Route.device(uid: "duo", channels: .stereo(1, 2)), false, true),
        (Route.app(bundleID: "us.zoom.xos"), true, false),
        (Route.device(uid: "duo", channels: .mono(2)), true, true),
    ])
    func addCallTracksDoesNotArmARouteInUse(armedRoute: Route, hostArms: Bool, guestArms: Bool) async throws {
        let (model, studio) = try await callWindow()
        let layout: ChannelLayout = if case .device(_, .stereo) = armedRoute { .stereo } else { .mono }
        try studio.edit(ripple: false) { s throws(SessionError) in
            try s.setRoute(nil, track: "t1")
            try s.setLayout(layout, route: armedRoute, track: "t2")
        }
        model.armed = ["t2"]
        model.addCallTracks(app: "us.zoom.xos")
        let tracks = studio.session.tracks
        try #require(tracks.count == 4)
        #expect(
            tracks[2].route == .device(uid: "duo", channels: .mono(1))
                && tracks[3].route == .app(bundleID: "us.zoom.xos"))
        #expect(model.armed.contains(tracks[2].id) == hostArms, "Host arm wrong for \(armedRoute)")
        #expect(model.armed.contains(tracks[3].id) == guestArms, "Guest arm wrong for \(armedRoute)")
        let zoom = InputDevice(
            uid: appUID("us.zoom.xos"), name: "zoom.us", nominalRate: 48_000, availableRates: [],
            channelsPerBuffer: [2], latency: 0)!
        let armed = tracks.map(\.id).filter(model.armed.contains)
        do {
            _ = try checkRoutes(studio.session, armed: armed, devices: [Self.duo, zoom])
        } catch {
            Issue.record("Record would fail: \(error)")
        }
    }

    /// An open arms the routed tracks in order, and a track that takes a channel of an earlier
    /// armed track stays unarmed with its route, so Record finds no channel in use (code gate E1).
    /// Control: two channels of one device both arm.
    @Test(arguments: [
        (Route.device(uid: "duo", channels: .mono(1)), Route.device(uid: "duo", channels: .stereo(1, 2)), false),
        (Route.app(bundleID: "us.zoom.xos"), Route.app(bundleID: "us.zoom.xos"), false),
        (Route.device(uid: "duo", channels: .mono(1)), Route.device(uid: "duo", channels: .mono(2)), true),
    ])
    func anOpenArmsNoChannelTwice(first: Route, second: Route, secondArms: Bool) async throws {
        let url = folder.url.appending(path: "overlap.dirigible")
        try await Task.detached {
            var session = Session(sampleRate: 48_000)
            let layout: ChannelLayout = if case .device(_, .stereo) = second { .stereo } else { .mono }
            try session.addTrack("t1", name: "A", layout: .mono)
            try session.addTrack("t2", name: "B", layout: layout)
            try session.setRoute(first, track: "t1")
            try session.setRoute(second, track: "t2")
            try session.write(to: url)
        }.value
        let model = await app.open(url)
        let studio = try #require(await model.opened() ? model.studio : nil)
        try await fixFreeSpace(model)
        #expect(model.armed.contains("t1"), "the first owner arms")
        #expect(model.armed.contains("t2") == secondArms, "the arm of t2 is wrong for \(second)")
        #expect(studio.session.track("t2")?.route == second, "the route stays")
        let zoom = InputDevice(
            uid: appUID("us.zoom.xos"), name: "zoom.us", nominalRate: 48_000, availableRates: [],
            channelsPerBuffer: [2], latency: 0)!
        do {
            _ = try checkRoutes(
                studio.session, armed: ["t1", "t2"].filter(model.armed.contains), devices: [Self.duo, zoom])
        } catch {
            Issue.record("Record would fail: \(error)")
        }
        await model.close()
    }
}
