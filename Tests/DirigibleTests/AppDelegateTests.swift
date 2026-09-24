import AppKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The window registry of the app delegate with real windows (probe P8) and real packages
/// (decision 0014).
@MainActor struct AppDelegateTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws { folder = try TemporaryFolder() }

    /// Criterion 15: `/tmp` and `/private/tmp` name one package.
    @Test func twoSpellingsOfOnePackageGiveOneWindow() async throws {
        let tmp = try TemporaryFolder(in: URL(filePath: "/tmp"))
        let package = try tmp.package("x")
        let first = app.open(package)
        let second = app.open(URL(filePath: "/private" + package.path))
        #expect(first === second)
        #expect(app.windows.count == 1)
        await closeAll()
    }

    @Test func twoPackagesGiveTwoWindows() async throws {
        app.open(try folder.package("a"))
        app.open(try folder.package("b"))
        #expect(app.windows.count == 2)
        await closeAll()
    }

    /// Criterion 7 (item 7; round 2, item 3): only a package in the list read at launch opens
    /// as recovering. The list has the `/private/var` spelling; the open gets the `/var` one.
    @Test func onlyAListedPackageOpensAsRecovering() async throws {
        let (listed, other) = (try folder.package("listed"), try folder.package("other"))
        #expect(listed.path.hasPrefix("/var/"))
        let list = folder.url.appending(path: "active-recordings.plist")
        try PropertyListEncoder().encode(["/private" + listed.path]).write(to: list)
        let app = AppDelegate(recordings: ActiveRecordings(file: list))

        let (a, b) = (app.open(listed), app.open(other))
        #expect(await a.opened())
        #expect(await b.opened())
        #expect(a.recovering)
        #expect(!b.recovering)
        for window in [a, b] { await window.close() }
    }

    /// Criterion 23 (item 1 sibling; round 2, item 5): the key follows a move, and a close
    /// removes the window also after the move.
    @Test func aMovedPackageKeepsOneEntryAndACloseRemovesIt() async throws {
        let old = try folder.package("old")
        let window = app.open(old)
        let new = folder.url.appending(path: "new.dirigible")
        weak var closedStudio: Studio?
        do {
            let studio = try #require(await window.opened() ? window.studio : nil)
            closedStudio = studio
            try FileManager.default.moveItem(at: old, to: new)
            try studio.edit { s throws(SessionError) in try s.addTrack("t1", name: "Host", layout: .mono) }
            await studio.settle()
        }
        await until("the registry follows the move") { app.windows[packageIdentity(new)] === window }
        #expect(app.windows.count == 1)
        #expect(window.url == packageIdentity(new))

        await window.close()
        #expect(app.windows.isEmpty)
        // The lock goes with the studio. A SwiftUI update that waits on a busy main actor can
        // hold the view, and so the studio, a little after the close.
        await until("the closed window drops its studio") { closedStudio == nil }
        let again = app.open(new)
        #expect(again !== window)
        #expect(await again.opened())
        await again.close()
    }

    /// Round 2, item 3 control: a write with no move keeps the URL and the key.
    @Test func anEditWithNoMoveKeepsTheKey() async throws {
        let package = packageIdentity(try folder.package("still"))
        let window = app.open(package)
        let studio = try #require(await window.opened() ? window.studio : nil)
        try studio.edit { s throws(SessionError) in try s.addTrack("t1", name: "Host", layout: .mono) }
        await studio.settle()
        try await Task.sleep(for: .milliseconds(100))
        #expect(Array(app.windows.keys) == [package])
        #expect(window.url == package)
        await window.close()
    }

    /// Criterion 25: a close after a failed autosave asks, and the window stays. Cancel keeps the
    /// same studio (round 2, item 4).
    @Test func aCloseWithAFailedSaveAsksAndCancelKeepsTheStudio() async throws {
        let window = app.open(try folder.package("failing"))
        let studio = try #require(await window.opened() ? window.studio : nil)
        studio.environment.saveSession = { _, _ throws(SessionFileError) in throw .writeFailed(step: "test", errno: EIO)
        }
        try studio.edit { s throws(SessionError) in try s.addTrack("t1", name: "Host", layout: .mono) }

        await window.close()
        #expect(window.alert == .confirmUnsavedClose)
        #expect(window.window?.isVisible == true)
        #expect(app.windows.count == 1)

        window.cancelUnsavedClose()
        guard case .open(let kept) = window.phase else {
            Issue.record("Cancel leaves the phase \(window.phase)")
            return
        }
        #expect(kept === studio)
        #expect(window.alert == nil)

        await window.close()
        window.closeAnyway()
        #expect(app.windows.isEmpty)
    }

    /// Criterion 25 control: a good save closes with no question.
    @Test func aCloseAfterAGoodSaveAsksNothing() async throws {
        let window = app.open(try folder.package("good"))
        let studio = try #require(await window.opened() ? window.studio : nil)
        try studio.edit { s throws(SessionError) in try s.addTrack("t1", name: "Host", layout: .mono) }
        await window.close()
        #expect(window.alert == nil)
        #expect(window.window == nil)
        #expect(app.windows.isEmpty)
    }

    private func closeAll() async {
        for window in app.windows.values { await window.close() }
    }
}
