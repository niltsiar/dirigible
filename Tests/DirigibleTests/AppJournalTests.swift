import AppKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The app journal of decision 0059 in a temporary folder: the launch starts it, Quit ends it, and
/// each studio of the app writes to it (C7, C41).
@MainActor struct AppJournalTests {
    let folder: TemporaryFolder
    let app: AppDelegate
    var logs: URL { folder.url.appending(path: "logs") }

    init() throws {
        folder = try TemporaryFolder()
        app = AppDelegate(recordings: nil, logFolder: folder.url.appending(path: "logs"))
    }

    @Test func theLaunchStartsTheJournalAndTheTerminateEndsIt() throws {
        app.applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))
        app.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))

        let names = ((try? FileManager.default.contentsOfDirectory(atPath: logs.path)) ?? []).filter {
            $0.hasSuffix(".tsv")
        }
        try #require(names.count == 1 && names[0].contains("-app-"), "files: \(names)")
        let text = String(decoding: try Data(contentsOf: logs.appending(path: names[0])), as: UTF8.self)
        let lines = text.split(separator: "\n")
        #expect(lines.count == 4 && lines[2].contains("\tapp\tlaunch\t"), "lines: \(lines)")
        #expect(lines.last?.split(separator: "\t").dropFirst(4).prefix(2) == ["app", "quit"])
    }

    @Test func theStudioOfAWindowAndOfNewSessionGetsTheAppLog() async throws {
        app.applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))
        #expect(app.log.isEnabled)

        let opened = await app.open(try folder.package("a"))
        #expect(await opened.opened())
        let created = folder.url.appending(path: "New.dirigible")
        #expect(await app.createSession(at: created) == nil)

        #expect(opened.studio?.log === app.log)
        #expect(app.windows[packageIdentity(created)]?.studio?.log === app.log)
        for window in app.windows.values { await window.close() }
    }
}
