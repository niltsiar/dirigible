import CoreAudio
import Foundation
import Testing

@testable import DirigibleAudio

/// The process match of an app (A4), the apps list (A3, A15), and the hidden tap aggregates
/// (A10). The fixtures are the process facts of probe P1 and app bundles in a temporary folder.
/// No test reads the real process list or LaunchServices.
struct AppTapTests {
    static let chromeClone =
        "/private/var/folders/3n/X/com.google.Chrome.code_sign_clone/code_sign_clone.V9PUsl/Google Chrome.app.bundle"
        + "/Contents/MacOS/Google Chrome"

    /// A4: by bundle ID equal or with a dot after it, or by a path inside the app bundle.
    @Test func theMatchTakesChromeHelpersAndNotChromeX() {
        let chrome = "/Applications/Google Chrome.app"
        let teams = "/Applications/Microsoft Teams.app"
        let processes = [
            AudioProcess(id: 1, bundleID: "com.google.Chrome", path: Self.chromeClone, playing: false),
            AudioProcess(
                id: 2, bundleID: "com.google.Chrome.helper",
                path: chrome + "/Contents/Frameworks/Helpers/Google Chrome Helper.app/Contents/MacOS/Helper",
                playing: true),
            AudioProcess(id: 3, bundleID: "com.google.ChromeX", path: "/Applications/ChromeX.app/X", playing: false),
            AudioProcess(id: 4, bundleID: "com.apple.WebKit.GPU", path: "/System/WebKit.framework/GPU", playing: true),
            AudioProcess(
                id: 5, bundleID: "", path: teams + "/Contents/Helpers/Microsoft Teams ModuleHost.app/Contents/MacOS/M",
                playing: true),
            AudioProcess(
                id: 6, bundleID: "com.microsoft.teams2.notificationcenter", path: "/tmp/elsewhere/nc", playing: false),
            AudioProcess(id: 7, bundleID: "", path: "/usr/sbin/systemstats", playing: false),
            AudioProcess(
                id: 8, bundleID: "com.microsoft.teams2", path: teams + "/Contents/MacOS/MSTeams", playing: false),
        ]
        #expect(appProcesses("com.google.Chrome", bundlePath: chrome, in: processes).map(\.id) == [1, 2], "Chrome")
        #expect(appProcesses("com.apple.Safari", bundlePath: "/Applications/Safari.app", in: processes).isEmpty, "GPU")
        #expect(appProcesses("com.microsoft.teams2", bundlePath: teams, in: processes).map(\.id) == [5, 6, 8], "Teams")
        #expect(
            appProcesses("com.google.Chrome", bundlePath: nil, in: processes).map(\.id) == [1, 2], "no bundle path")
    }

    /// A3 and A15: one entry for each regular app, by its bundle ID; a helper playing flag counts
    /// for its app; Chrome (main process from a clone path) is listed once; agents, background
    /// apps, daemons, and XPC services are not listed.
    @Test func theListGroupsChromeOnceAndDropsAgents() throws {
        let apps = try AppFixture()
        let list = appList(apps.processes, appURL: apps.url(of:))
        #expect(
            list.map(\.bundleID) == ["com.google.Chrome", "com.microsoft.teams2", "us.zoom.xos"],
            "the regular apps by name")
        #expect(list.map(\.name) == ["Google Chrome", "Microsoft Teams", "zoom.us"])
        #expect(list.map(\.playing) == [true, true, false], "a helper playing flag counts for its app")
        #expect(!list.contains { $0.bundleID == "com.apple.controlcenter" }, "an LSUIElement agent is not listed")
        #expect(!list.contains { $0.bundleID == "com.example.background" }, "an LSBackgroundOnly app is not listed")
    }

    /// The list and the tap agree: `appProcesses` of each listed app gives its listed processes.
    @Test func eachListedAppMatchesItsProcesses() throws {
        let apps = try AppFixture()
        let list = appList(apps.processes, appURL: apps.url(of:))
        try #require(list.count == 3)
        for app in list {
            let matched = appProcesses(app.bundleID, bundlePath: app.path, in: apps.processes).map(\.id)
            #expect(matched == app.processes, "\(app.bundleID)")
        }
    }

    /// A10: `InputDevice.all()` and the route menu never list a tap aggregate of Dirigible, which
    /// the creating process sees (probe P9d). Other `com.` UIDs stay.
    @Test func theDeviceListHidesTheTapAggregates() throws {
        let uids = ["BuiltInMicrophoneDevice", "com.delineas.dirigible.tap.5F1C", "com.rogueamoeba.Loopback:1"]
        let devices = try uids.map { try #require(InputDevice.placeholder(uid: $0, channels: 2)) }
        #expect(
            visibleInputs(devices).map(\.uid) == ["BuiltInMicrophoneDevice", "com.rogueamoeba.Loopback:1"],
            "only the tap aggregate goes")
    }
}

/// App bundles in a temporary folder, with the process facts of probe P1, and a LaunchServices
/// lookup that knows only these bundles.
struct AppFixture {
    let root: URL
    let processes: [AudioProcess]
    private let urls: [String: URL]

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "AppTapTests-\(UUID().uuidString)")
        let chrome = root.appending(path: "Google Chrome.app")
        let helper = chrome.appending(path: "Contents/Frameworks/Helpers/Google Chrome Helper.app")
        let teams = root.appending(path: "Microsoft Teams.app")
        let moduleHost = teams.appending(path: "Contents/Helpers/Microsoft Teams ModuleHost.app")
        let zoom = root.appending(path: "zoom.us.app")
        let controlCenter = root.appending(path: "ControlCenter.app")
        let background = root.appending(path: "Background.app")
        let xpc = root.appending(path: "Service.xpc")
        try Self.bundle(chrome, "com.google.Chrome", "Google Chrome")
        try Self.bundle(helper, "com.google.Chrome.helper", "Google Chrome Helper", extra: ["LSUIElement": true])
        try Self.bundle(teams, "com.microsoft.teams2", "Microsoft Teams")
        try Self.bundle(moduleHost, "com.microsoft.teams2.modulehost", "ModuleHost", extra: ["LSUIElement": "1"])
        try Self.bundle(zoom, "us.zoom.xos", "zoom.us")
        try Self.bundle(controlCenter, "com.apple.controlcenter", "Control Center", extra: ["LSUIElement": true])
        try Self.bundle(background, "com.example.background", "Background", extra: ["LSBackgroundOnly": true])
        try Self.bundle(xpc, "com.example.service", "Service", type: "XPC!")
        urls = [
            "com.google.Chrome": chrome, "com.google.Chrome.helper": helper, "com.microsoft.teams2": teams,
            "us.zoom.xos": zoom, "com.apple.controlcenter": controlCenter, "com.example.background": background,
            "com.example.service": xpc,
        ]
        let helperPath = helper.path + "/Contents/MacOS/Google Chrome Helper"
        processes = [
            AudioProcess(id: 191, bundleID: "com.google.Chrome", path: AppTapTests.chromeClone, playing: false),
            AudioProcess(id: 192, bundleID: "com.google.Chrome.helper", path: helperPath, playing: true),
            AudioProcess(id: 193, bundleID: "com.google.Chrome.helper", path: helperPath, playing: false),
            // First, so the Teams entry takes its path from a helper with no bundle ID.
            AudioProcess(id: 201, bundleID: "", path: moduleHost.path + "/Contents/MacOS/ModuleHost", playing: true),
            AudioProcess(
                id: 200, bundleID: "com.microsoft.teams2", path: teams.path + "/Contents/MacOS/MSTeams", playing: false),
            AudioProcess(id: 210, bundleID: "us.zoom.xos", path: zoom.path + "/Contents/MacOS/zoom.us", playing: false),
            AudioProcess(
                id: 167, bundleID: "com.apple.controlcenter",
                path: controlCenter.path + "/Contents/MacOS/ControlCenter",
                playing: false),
            AudioProcess(
                id: 220, bundleID: "com.example.background", path: background.path + "/Contents/MacOS/B", playing: true),
            AudioProcess(id: 230, bundleID: "com.example.service", path: xpc.path + "/Contents/MacOS/S", playing: true),
            AudioProcess(id: 166, bundleID: "", path: "/usr/sbin/systemstats", playing: false),
            AudioProcess(
                id: 181, bundleID: "com.apple.WebKit.GPU", path: "/System/WebKit.framework/GPU", playing: true),
        ]
    }

    func url(of bundleID: String) -> URL? { urls[bundleID] }

    private static func bundle(
        _ url: URL, _ id: String, _ name: String, type: String = "APPL", extra: [String: Any] = [:]
    ) throws {
        let contents = url.appending(path: "Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundlePackageType": type].merging(extra) { $1 }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
        try data.write(to: contents.appending(path: "Info.plist"))
    }
}
