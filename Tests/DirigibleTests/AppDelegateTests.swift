import AppKit
import DirigibleCore
import Foundation
import Testing
import os

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
        let first = await app.open(package)
        let second = await app.open(URL(filePath: "/private" + package.path))
        #expect(first === second)
        #expect(app.windows.count == 1)
        await closeAll()
    }

    @Test func twoPackagesGiveTwoWindows() async throws {
        await app.open(try folder.package("a"))
        await app.open(try folder.package("b"))
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

        let (a, b) = (await app.open(listed), await app.open(other))
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
        let window = await app.open(old)
        let new = folder.url.appending(path: "new.dirigible")
        weak var closedStudio: Studio?
        do {
            let studio = try #require(await window.opened() ? window.studio : nil)
            closedStudio = studio
            try FileManager.default.moveItem(at: old, to: new)
            try studio.edit(ripple: false) { s throws(SessionError) in try s.addTrack("t1", name: "Host", layout: .mono)
            }
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
        let again = await app.open(new)
        #expect(again !== window)
        #expect(await again.opened())
        await again.close()
    }

    /// Code gate 1, item 5: a move onto the stale key of another window keeps both windows in
    /// the registry, so Quit still settles both.
    @Test func aMoveOntoTheStaleKeyOfAnotherWindowKeepsBoth() async throws {
        let (a, b) = (try folder.package("a"), try folder.package("b"))
        let first = await app.open(a)
        let second = await app.open(b)
        #expect(await second.opened())
        let studio = try #require(await first.opened() ? first.studio : nil)
        // B moves and does not write, so the registry still has B at its old path. Then A
        // moves to that path.
        try FileManager.default.moveItem(at: b, to: folder.url.appending(path: "c.dirigible"))
        try FileManager.default.moveItem(at: a, to: b)
        try studio.edit(ripple: false) { s throws(SessionError) in try s.addTrack("t1", name: "Host", layout: .mono) }
        await studio.settle()
        await until("the first window follows the move") { first.url == packageIdentity(b) }
        try await Task.sleep(for: .milliseconds(100))

        #expect(
            Set(app.windows.values.map(ObjectIdentifier.init)) == [ObjectIdentifier(first), ObjectIdentifier(second)])
        #expect(app.windows[packageIdentity(b)] === second)
        await closeAll()
    }

    /// Round 2, item 3 control: a write with no move keeps the URL and the key.
    @Test func anEditWithNoMoveKeepsTheKey() async throws {
        let package = packageIdentity(try folder.package("still"))
        let window = await app.open(package)
        let studio = try #require(await window.opened() ? window.studio : nil)
        try studio.edit(ripple: false) { s throws(SessionError) in try s.addTrack("t1", name: "Host", layout: .mono) }
        await studio.settle()
        try await Task.sleep(for: .milliseconds(100))
        #expect(Array(app.windows.keys) == [package])
        #expect(window.url == package)
        await window.close()
    }

    /// Criterion 25: a close after a failed autosave asks, and the window stays. Cancel keeps the
    /// same studio (round 2, item 4).
    @Test func aCloseWithAFailedSaveAsksAndCancelKeepsTheStudio() async throws {
        let window = await app.open(try folder.package("failing"))
        let studio = try #require(await window.opened() ? window.studio : nil)
        studio.environment.saveSession = { _, _ throws(SessionFileError) in throw .writeFailed(step: "test", errno: EIO)
        }
        try studio.edit(ripple: false) { s throws(SessionError) in try s.addTrack("t1", name: "Host", layout: .mono) }

        // AppKit asks the delegate of the window, so the test calls the same witness.
        let nsWindow = try #require(window.window)
        let delegate = try #require(nsWindow.delegate, "the window has a delegate")
        let shouldClose = try #require(delegate.windowShouldClose, "the window delegate has a close witness")
        #expect(shouldClose(nsWindow) == false)
        await until(limit: .seconds(30), "the close asks") { window.alert == .confirmUnsavedClose }
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

    /// Decision 0017: the settle of a close starts no peak pass, so a cancelled unsaved close
    /// starts one; the files of a take that the settle finalized get their peaks. The test
    /// empties the peak states after the settle.
    @Test func aCancelledUnsavedCloseLoadsPeaks() async throws {
        let (window, studio) = try await windowWithPeaks()
        studio.environment.saveSession = { _, _ throws(SessionFileError) in throw .writeFailed(step: "test", errno: EIO)
        }
        try studio.edit(ripple: false) { s throws(SessionError) in try s.renameTrack("t1", to: "Host") }
        await window.close()
        #expect(window.alert == .confirmUnsavedClose)
        studio.peakLoad.states = [:]

        window.cancelUnsavedClose()

        await until(limit: .seconds(30), "the cancel loads the peaks") { studio.peaks["f1"]?.peaks != nil }
        await window.close()
        window.closeAnyway()
    }

    /// Decision 0017: a focus loads the peaks again, because a WAV can change outside the app.
    @Test func aFocusLoadsPeaks() async throws {
        let (window, studio) = try await windowWithPeaks()
        // AppKit tells the delegate of the window, so the model needs its window.
        window.show()
        studio.peakLoad.states = [:]

        let delegate = try #require(window.window?.delegate, "the window has a delegate")
        let becomeKey = try #require(delegate.windowDidBecomeKey, "the window delegate has a focus witness")
        becomeKey(Notification(name: NSWindow.didBecomeKeyNotification))

        await until(limit: .seconds(30), "the focus loads the peaks") { studio.peaks["f1"]?.peaks != nil }
        await window.close()
    }

    /// Code gate 1 item 2: the launch removes the peak cache files that were not used for 90
    /// days, off the main actor, and keeps the others.
    @Test func theLaunchPrunesThePeakCache() async throws {
        let cache = folder.url.appending(path: "Peaks")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let (old, used) = (cache.appending(path: "old.peaks"), cache.appending(path: "used.peaks"))
        for (url, days) in [(old, 91.0), (used, 89.0)] {
            try Data([1]).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date.now.addingTimeInterval(-days * 86_400)], ofItemAtPath: url.path)
        }

        _ = AppDelegate(recordings: nil, peakCache: cache)

        await until("the launch prunes the peak cache") { !FileManager.default.fileExists(atPath: old.path) }
        #expect(FileManager.default.fileExists(atPath: used.path))
    }

    /// A session window model (no window on screen) on a package with one 1 s WAV, with a peak
    /// cache folder, after its first pass.
    private func windowWithPeaks() async throws -> (SessionWindow, Studio) {
        let app = AppDelegate(recordings: nil, peakCache: folder.url.appending(path: "Peaks"))
        let (window, studio) = try await timelineModel(
            try await timelinePackage(in: folder.url, tracks: 1, seconds: 1, audio: true), app: app)
        await until(limit: .seconds(30), "the open loads the peaks") { studio.peaks["f1"]?.peaks != nil }
        return (window, studio)
    }

    /// Criterion 25 control: a good save closes with no question.
    @Test func aCloseAfterAGoodSaveAsksNothing() async throws {
        let window = await app.open(try folder.package("good"))
        let studio = try #require(await window.opened() ? window.studio : nil)
        try studio.edit(ripple: false) { s throws(SessionError) in try s.addTrack("t1", name: "Host", layout: .mono) }
        await window.close()
        #expect(window.alert == nil)
        #expect(window.window == nil)
        #expect(app.windows.isEmpty)
    }

    /// Code gate 1, item 1: a grant that comes after a close during the first microphone prompt
    /// starts no take. Control: a grant with the window open starts the take (criterion 14).
    @Test(arguments: [true, false])
    func aGrantAfterACloseStartsNoTake(closed: Bool) async throws {
        let mic = try #require(
            InputDevice(
                uid: "mic", name: "USB Mic", nominalRate: 48_000, availableRates: [48_000...48_000],
                channelsPerBuffer: [1], latency: 0))
        let package = folder.url.appending(path: "prompt.dirigible")
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.setRoute(Route.device(uid: mic.uid, channels: .mono(1)), track: "t1")
        try session.write(to: package)
        let window = await app.open(package)
        let studio = try #require(await window.opened() ? window.studio : nil)
        let granted = OSAllocatedUnfairLock(initialState: false)
        studio.environment = CaptureEnvironment(
            hal: DeviceHAL(
                lookUp: { $0 == mic.uid ? (1, mic) : nil }, attach: { _ in { true } }, watchDevices: { _ in { true } },
                attachListen: { _ in (512, 48_000, { true }) }),
            silenceLimit: noWatchdog, firstRecordLimit: noWatchdog,
            microphoneAccess: { granted.withLock { $0 } ? nil : .notDetermined }, freeBytes: { _ in .max },
            diskCheckInterval: .seconds(60), saveSession: CaptureEnvironment.live.saveSession,
            listenOutput: .offline())
        let (answer, give) = AsyncStream<Void>.makeStream()
        var asked = false
        window.requestMicrophoneAccess = {
            asked = true
            for await _ in answer { break }
            granted.withLock { $0 = true }
            return true
        }

        let record = Task { await window.record() }
        await until("Record asks for the access") { asked }
        if closed { await window.close() }
        give.yield()
        await record.value

        #expect(try Session(contentsOf: package).recording == nil ? closed : !closed)
        #expect(studio.transport == (closed ? .idle : .recording(take: 1)))
        try? await studio.stopRecording()
        await window.close()
    }

    /// Code gate 1, item 2: Record, Close, and Quit (`settle`) save a typed name that the user
    /// did not submit.
    @Test(arguments: ["record", "close", "quit"])
    func aTypedNameThatIsNotSubmittedIsSaved(by action: String) async throws {
        let package = try folder.package("typed")
        let window = await app.open(package)
        let studio = try #require(await window.opened() ? window.studio : nil)
        try studio.edit(ripple: false) { s throws(SessionError) in try s.addTrack("t1", name: "Host", layout: .mono) }

        window.drafts["t1"] = "Guest"
        switch action {
        case "record": await window.record()
        case "close": await window.close()
        default: await window.settle()
        }
        await studio.settle()

        #expect(try Session(contentsOf: package).track("t1")?.name == "Guest")
        #expect(window.drafts.isEmpty)
        await window.close()
    }

    /// Code gate 1, item 2: a refused name goes, so the field shows the saved name again.
    @Test func aRefusedNameGivesBackTheSavedName() async throws {
        let window = await app.open(try folder.package("refused"))
        let studio = try #require(await window.opened() ? window.studio : nil)
        try studio.edit(ripple: false) { s throws(SessionError) in try s.addTrack("t1", name: "Host", layout: .mono) }

        window.drafts["t1"] = "Tab\t"
        window.commitName("t1")

        #expect(window.alert == .error(.session(.invalidText("Tab\t"))))
        #expect(window.drafts["t1"] == nil)
        #expect(studio.session.track("t1")?.name == "Host")
        await window.close()
    }

    /// Code gate 1, item 4: New Session makes the package through `Studio.create` and shows its
    /// studio. Control: a path that exists gives `.exists` and no second window (criterion 10).
    @Test func newSessionCreatesThePackageAndShowsIt() async throws {
        let url = folder.url.appending(path: "New.dirigible")

        #expect(await app.createSession(at: url) == nil)

        let window = try #require(app.windows[packageIdentity(url)])
        #expect(window.studio?.session == Session(sampleRate: 48_000))
        #expect(try Session(contentsOf: url) == Session(sampleRate: 48_000))
        #expect(await app.createSession(at: url) == .file(.exists))
        #expect(app.windows.count == 1)
        await window.close()
    }

    /// An executable with no Info.plist gets the folders of the real app; a verify copy gets its own.
    @Test func theFoldersFollowTheBundleID() {
        let (support, caches) = (URL(filePath: "/S"), URL(filePath: "/C"))
        let real = AppDelegate.folders(bundleID: nil, support: support, caches: caches)
        #expect(real.recordings.path == "/S/com.delineas.dirigible/active-recordings.plist")
        #expect(real.peakCache.path == "/C/com.delineas.dirigible/Peaks")
        let id = "com.delineas.dirigible.verify-0123abcd"
        let copy = AppDelegate.folders(bundleID: id, support: support, caches: caches)
        #expect(copy.recordings.path == "/S/\(id)/active-recordings.plist")
        #expect(copy.peakCache.path == "/C/\(id)/Peaks")
    }

    private func closeAll() async {
        for window in app.windows.values { await window.close() }
    }
}
