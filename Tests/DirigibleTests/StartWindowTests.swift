import AppKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The start window and its triggers (decision 0027), with real windows and real packages. Only
/// this suite gives the app delegate a default folder, so only it shows start windows. It runs
/// serialized, because a start window takes the key window, which is a shared resource.
@Suite(.serialized) @MainActor struct StartWindowTests {
    let folder: TemporaryFolder
    let app: AppDelegate

    init() throws {
        NSWindow.allowsAutomaticWindowTabbing = false
        folder = try TemporaryFolder()
        app = AppDelegate(recordings: nil, defaultFolder: folder.url.appending(path: "Music/Dirigible"))
    }

    /// Criterion C1.
    @Test func aLaunchWithNoSessionShowsTheStartWindow() async throws {
        await app.openAtLaunch()

        #expect(app.start?.window?.isVisible == true, "the launch with no session shows the start window")
        await closeAll(app)
    }

    /// Criterion C2: the recovered session opens, and the start window does not show.
    @Test func aLaunchWithAListedRecordingShowsNoStartWindow() async throws {
        let listed = try folder.package("listed")
        let list = folder.url.appending(path: "active-recordings.plist")
        try PropertyListEncoder().encode([listed.path]).write(to: list)
        let app = AppDelegate(recordings: ActiveRecordings(file: list), defaultFolder: folder.url)

        await app.openAtLaunch()

        #expect(app.windows.count == 1)
        #expect(app.start == nil, "a recovered session hides the start window")
        await closeAll(app)
    }

    /// Plan slice 1, the open events guard: an open event that waits at the launch check hides the
    /// start window, also before its window is in the registry.
    @Test func anOpenEventAtLaunchShowsNoStartWindow() async throws {
        let package = try folder.package("a")
        _ = await app.listedAtLaunch.value

        app.application(NSApp, open: [package])
        await app.openAtLaunch()

        #expect(app.start == nil, "an open event that waits hides the start window")
        await until("the open event opens its window") { app.windows.count == 1 }
        await closeAll(app)
    }

    /// Criterion C3: a Dock click shows the start window only when no session window is open.
    @Test(arguments: [false, true])
    func aReopenShowsTheStartWindowOnlyWithNoSession(hasSession: Bool) async throws {
        if hasSession { await app.open(try folder.package("a")) }

        #expect(app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: hasSession))

        if hasSession {
            #expect(app.start == nil, "a reopen with a session window shows no start window")
        } else {
            #expect(app.start?.window?.isVisible == true, "a reopen with no session window shows the start window")
        }
        await closeAll(app)
    }

    /// Criterion C4.
    @Test(arguments: [1, 2])
    func theLastCloseShowsTheStartWindow(windows count: Int) async throws {
        var opened: [SessionWindow] = []
        for index in 0..<count { opened.append(await app.open(try folder.package("p\(index)"))) }

        await opened[0].close()

        if count == 1 {
            #expect(app.start?.window?.isVisible == true, "the last close shows the start window")
        } else {
            #expect(app.start == nil, "the close of one of two windows shows no start window")
        }
        await closeAll(app)
    }

    /// Criterion C5: the test init has no default folder, so no trigger shows a start window.
    @Test func noSessionFolderShowsNoStartWindow() async throws {
        let app = AppDelegate(recordings: nil)

        await app.openAtLaunch()
        #expect(app.start == nil, "no session folder: the launch shows no start window")
        await app.open(try folder.package("a")).close()
        #expect(app.start == nil, "no session folder: the last close shows no start window")
        _ = app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        #expect(app.start == nil, "no session folder: a reopen shows no start window")
    }

    /// Criterion C14 (plan gate, item 6): an open closes the start window, also the open of a
    /// session that is already open.
    @Test(arguments: [false, true])
    func anOpenClosesTheStartWindow(existing: Bool) async throws {
        let package = try folder.package("a")
        if existing { await app.open(package) }
        app.showStart()
        #expect(app.start?.window?.isVisible == true)

        await app.open(package)

        #expect(app.start == nil, "an open closes the start window")
        #expect(app.windows.count == 1)
        await closeAll(app)
    }

    /// Criterion C15: the start window is not a session window, so a plain key goes to the control
    /// with the focus and not to the transport. With no row, the focus is in the name field. With a
    /// recent row, the focus is in the list (C13), and the window class alone keeps the keys there.
    @Test(arguments: [StartField.name, .list])
    func thePlainKeysGoToTheStartWindow(focus: StartField) async throws {
        if focus == .list { app.recent = [try folder.package("a")] }
        app.showStart()
        let model = try #require(app.start?.model)
        let window = try #require(app.start?.window)
        if focus == .name {
            await until("the name field has the focus") { nameEditor(in: window) != nil }
        } else {
            await model.rowsTask?.value
            await model.scanTask?.value
            await until("the list has the focus") {
                window.contentView?.layoutSubtreeIfNeeded()
                return window.firstResponder is NSTableView
            }
        }

        #expect(!takesTransportKeys(window), "the start window takes no transport keys")
        if focus == .name {
            #expect(forwardTypingKey(key(.keyDown, "j", code: 38, in: window), in: window))
            await until("a plain key types into the name field") { model.name.contains("j") }
        } else {
            let keys: [(String, UInt16)] = [(" ", 49), ("j", 38), ("k", 40), ("l", 37)]
            for (text, code) in keys {
                #expect(
                    forwardTypingKey(key(.keyDown, text, code: code, in: window), in: window), "the list gets '\(text)'"
                )
            }
            #expect(window.firstResponder is NSTableView, "the list keeps the focus after the plain keys")
            #expect(app.start != nil, "the plain keys open no row")
        }
        await closeAll(app)
    }

    /// Criterion C19: Window > Start Window shows the start window while a session window is open,
    /// and the session window stays.
    @Test func theWindowMenuShowsTheStartWindowWithASession() async throws {
        await app.open(try folder.package("a"))

        app.showStart()

        #expect(
            app.start?.window?.isVisible == true, "Start Window shows the start window with a session open")
        #expect(app.windows.count == 1)
        await closeAll(app)
    }

    /// A close by the user drops the start window, and the next show makes a new one.
    @Test func aClosedStartWindowShowsAgain() async throws {
        app.showStart()
        let first = try #require(app.start?.window)

        first.performClose(nil)

        #expect(app.start == nil, "a closed start window is gone")
        app.newSession()
        #expect(app.start?.window?.isVisible == true)
        #expect(app.start?.window !== first)
        await closeAll(app)
    }

    /// Criterion C6 (plan gate, item 7): after the quit decision, the last close shows no start
    /// window. With no session window, `applicationShouldTerminate` returns at once and calls no
    /// reply, so the test runner does not quit.
    @Test func aQuitShowsNoStartWindow() async throws {
        #expect(app.applicationShouldTerminate(NSApp) == .terminateNow)

        await app.open(try folder.package("a")).close()

        #expect(app.start == nil, "no start window shows during a quit")
    }

    /// Closes the session windows, then the start window that the last close shows.
    func closeAll(_ app: AppDelegate) async {
        for window in app.windows.values { await window.close() }
        app.start?.window?.close()
    }
}
