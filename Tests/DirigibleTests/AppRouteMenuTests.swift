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
}
