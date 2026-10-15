import AppKit
import DirigibleCore
import Foundation
import Testing
import os

@testable import DirigibleApp
@testable import DirigibleAudio

/// The recent list, the focus, and Return in the start window (decision 0027). An extension of
/// `StartWindowTests`, so these tests run serialized with the other start windows.
extension StartWindowTests {
    var missing: URL { folder.url.appending(path: "missing.dirigible") }

    /// Criterion C23: the recent list is in the app preferences, so a new build keeps it. The list
    /// of `NSDocumentController` belongs to one code signature, and each ad-hoc build has a new one.
    @Test func theRecentListComesFromThePreferences() async throws {
        let domain = "dirigible.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let a = try folder.package("a")
        let first = AppDelegate(recordings: nil, defaults: defaults)
        await first.open(a)
        await closeAll(first)

        let next = AppDelegate(recordings: nil, defaults: defaults)
        #expect(next.recent.map(\.path) == [packageIdentity(a).path], "the next launch lists it")
        #expect(AppDelegate(recordings: nil).recent.isEmpty, "the list is not the list of NSDocumentController")
        await next.open(a)
        #expect(next.recent.map(\.path) == [packageIdentity(a).path], "an open of a listed session adds no row")
        await closeAll(next)
    }

    /// Criterion C23: the load keeps only absolute paths; an open moves its session to the top with
    /// no second row, and the list keeps the 10 newest.
    @Test func theRecentListKeepsTenAbsolutePathsNewestFirst() async throws {
        let domain = "dirigible.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let (a, b) = (packageIdentity(try folder.package("a")).path, packageIdentity(try folder.package("b")).path)
        let gone = (0..<9).map { "/gone/\($0).dirigible" }
        defaults.set(["", "relative.dirigible", gone[0], a] + gone[1...], forKey: "recent.sessions")
        let app = AppDelegate(recordings: nil, defaults: defaults)
        #expect(app.recent.map(\.path) == [gone[0], a] + gone[1...], "the load keeps only absolute paths")

        await app.open(URL(fileURLWithPath: a))
        #expect(app.recent.map(\.path) == [a] + gone, "an open moves its session to the top with no second row")
        await app.open(URL(fileURLWithPath: b))
        let expected = [b, a] + gone[..<8]
        #expect(app.recent.map(\.path) == expected, "the list keeps the 10 newest")
        #expect(defaults.stringArray(forKey: "recent.sessions") == expected, "the preference holds the list")
        await closeAll(app)
    }

    /// Code gate 1, item 2: a move that the registry follows puts the new path in place of the
    /// old path in the recent list and the preference, in the same order and with no second row.
    @Test func aMoveReplacesThePathInTheRecentList() async throws {
        let domain = "dirigible.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let app = AppDelegate(recordings: nil, defaults: defaults)
        let (old, other) = (try folder.package("old"), try folder.package("other"))
        await app.open(other)
        let window = await app.open(old)
        let studio = try #require(await window.opened() ? window.studio : nil)
        let new = folder.url.appending(path: "new.dirigible")
        try FileManager.default.moveItem(at: old, to: new)
        let moved = packageIdentity(new)
        // A stale row of another session at the new path.
        app.recent.append(moved)

        try studio.edit(ripple: false) { s throws(SessionError) in try s.addTrack("t1", name: "Host", layout: .mono) }
        await studio.settle()
        await until("the registry follows the move") { app.windows[moved] === window }

        let expected = [moved.path, packageIdentity(other).path]
        #expect(app.recent.map(\.path) == expected, "the recent list has the new path in place of the old path")
        #expect(defaults.stringArray(forKey: "recent.sessions") == expected, "the preference has the new path")
        await closeAll(app)
    }

    /// Code gate 1, item 3: File > Open Recent > Clear Menu empties the recent list, the
    /// preference, and the rows of a start window that shows.
    @Test func clearMenuEmptiesTheRecentList() async throws {
        let domain = "dirigible.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let app = AppDelegate(recordings: nil, defaults: defaults, defaultFolder: sessions)
        await app.open(try folder.package("a"))
        app.showStart()
        let model = try #require(app.start?.model)
        await model.rowsTask?.value
        #expect(model.rows.count == 1)

        app.clearRecent()
        await model.rowsTask?.value

        #expect(app.recent.isEmpty, "Clear Menu empties the recent list")
        #expect(defaults.stringArray(forKey: "recent.sessions") == [], "Clear Menu empties the preference")
        #expect(model.rows.isEmpty, "Clear Menu empties the rows of the start window")
        await closeAll(app)
    }

    /// Criterion C12: each recent URL gives a row in its order, a missing package shows as missing,
    /// and the first row that exists is selected.
    @Test func theRecentListMarksMissingPackagesAndSelectsTheFirstThatExists() async throws {
        let (a, b) = (try folder.package("a"), try folder.package("b"))
        let onMain = OSAllocatedUnfairLock(initialState: [Bool]())
        app.exists = { url in
            onMain.withLock { $0.append(Thread.isMainThread) }
            return FileManager.default.fileExists(atPath: url.path)
        }
        app.recent = [missing, a, b]
        app.showStart()
        let model = try #require(app.start?.model)
        await model.rowsTask?.value

        #expect(model.rows.map(\.name) == ["missing", "a", "b"])
        #expect(model.rows.map(\.exists) == [false, true, true], "a missing package shows as missing")
        #expect(model.rows.map(\.folder) == Array(repeating: folder.url.lastPathComponent, count: 3))
        #expect(model.selection == a, "the selection is the first row that exists")
        let calls = onMain.withLock { $0 }
        #expect(!calls.isEmpty && !calls.contains(true), "the existence check runs off the main actor")
        await closeAll(app)
    }

    /// Code gate 1, item 5: a second show and New Session keep a selection that is still in the
    /// rows. A selection that left the recent list goes to the first row that the check found.
    @Test func aShowKeepsASelectionThatIsStillInTheRows() async throws {
        let (a, b) = (try folder.package("a"), try folder.package("b"))
        app.recent = [a, b]
        app.showStart()
        let model = try #require(app.start?.model)
        await model.rowsTask?.value
        model.select(b)

        app.showStart()
        await model.rowsTask?.value
        #expect(model.selection == b, "a second show keeps the selection")
        app.newSession()
        await model.rowsTask?.value
        #expect(model.selection == b, "New Session keeps the selection")

        app.recent = [a]
        app.showStart()
        await model.rowsTask?.value
        #expect(model.rows.map(\.url) == [a])
        #expect(model.selection == a, "a selection that left the list goes to the first row found")
        await closeAll(app)
    }

    /// Criterion C13: the focus before the rows follows the raw URL list; after the rows, it is in
    /// the list only when a row exists. New Session puts it in the name field.
    @Test(arguments: ["a", "missing", "none"])
    func theFocusStartsInTheListOnlyWhenARowExists(recent: String) async throws {
        let urls = ["a": [try folder.package("a")], "missing": [missing], "none": []][recent] ?? []
        app.recent = urls
        app.showStart()
        let model = try #require(app.start?.model)

        #expect(model.focus == (urls.isEmpty ? .name : .list), "the focus before the rows follows the recent URLs")
        await model.rowsTask?.value
        #expect(
            model.focus == (recent == "a" ? .list : .name),
            "the focus after the rows is in the list only when a row exists")
        app.newSession()
        #expect(model.focus == .name, "New Session puts the focus in the name field")
        await closeAll(app)
    }

    /// Criterion C22 (plan gate, item 1): a rows result after a user edit keeps the focus and the
    /// text.
    @Test func aUserActKeepsTheFocus() async throws {
        let a = try folder.package("a")
        app.recent = [a]
        app.showStart()
        let model = try #require(app.start?.model)

        model.edit("typed")
        await model.rowsTask?.value

        #expect(model.rows.count == 1)
        #expect(model.focus == .name, "a result after a user act keeps the focus")
        #expect(model.name == "typed")
        await closeAll(app)
    }

    /// Criterion C22: a second show while the rows scan runs reuses that scan.
    @Test func twoShowsRunOneRowsScan() async throws {
        let a = try folder.package("a")
        let checks = OSAllocatedUnfairLock(initialState: 0)
        app.exists = { url in
            if url == a { checks.withLock { $0 += 1 } }
            return FileManager.default.fileExists(atPath: url.path)
        }
        app.recent = [a]

        app.showStart()
        app.showStart()
        await app.start?.model.rowsTask?.value

        #expect(checks.withLock { $0 } == 1, "a second show reuses the running rows scan")
        await closeAll(app)
    }

    /// Criterion C22: a rows result after the close of the start window changes nothing.
    @Test func aClosedStartWindowDropsTheRowsResult() async throws {
        let a = try folder.package("a")
        app.recent = [a]
        app.showStart()
        let model = try #require(app.start?.model)
        let task = model.rowsTask

        app.start?.window?.performClose(nil)
        await task?.value

        #expect(app.start == nil, "a close with no Create drops the start window")
        #expect(model.rows.isEmpty, "a closed start window takes no rows result")
    }

    /// Criterion C13: Return acts on the control with the focus. In the name field it creates the
    /// session; in the list it opens the selected session and makes no package.
    @Test(arguments: [StartField.name, .list])
    func returnOpensTheSelectionOrCreates(focus: StartField) async throws {
        let a = try folder.package("a")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        app.recent = [a]
        app.showStart()
        let model = try #require(app.start?.model)
        let window = try #require(app.start?.window)
        await model.rowsTask?.value
        await model.scanTask?.value
        if focus == .name {
            app.newSession()
            model.edit("typed")
            await until("the name field has the focus") { nameEditor(in: window) != nil }
        } else {
            await until("the list has the focus") {
                window.contentView?.layoutSubtreeIfNeeded()
                return window.firstResponder is NSTableView
            }
        }

        let down = key(.keyDown, "\r", code: 36, in: window)
        if !window.performKeyEquivalent(with: down) { window.sendEvent(down) }
        window.sendEvent(key(.keyUp, "\r", code: 36, in: window))

        if focus == .name {
            await until("Return in the name field creates the session") { app.windows.count == 1 }
            #expect(FileManager.default.fileExists(atPath: sessions.appending(path: "typed.dirigible").path))
        } else {
            await until("Return in the list opens the selection") { app.windows[packageIdentity(a)] != nil }
            let made = (try? FileManager.default.contentsOfDirectory(atPath: sessions.path)) ?? []
            #expect(made.isEmpty, "Return in the list makes no package")
        }
        #expect(app.start == nil)
        await closeAll(app)
    }

    /// Code gate 1, item 1: "Not found" is a hint only. The open of a missing package gives its
    /// own error in the session window, and the start window closes.
    @Test func aNotFoundRowOpensAndItsWindowShowsTheOpenError() async throws {
        app.recent = [missing]
        app.showStart()
        let model = try #require(app.start?.model)
        await model.rowsTask?.value
        #expect(model.rows.map(\.exists) == [false])

        await model.open(missing)

        let window = try #require(app.windows.values.first, "a Not found row opens its session window")
        await until("the open of the missing package fails") {
            if case .failed = window.phase { true } else { false }
        }
        if case .failed(let error) = window.phase {
            #expect("\(error)".contains("\(ENOENT)"), "the window shows the error of the open: \(error)")
        }
        #expect(app.start == nil, "a row open closes the start window")
        await closeAll(app)
    }

    /// Code gate 1, item 1: a package that the existence check cannot see (a denied path) is a
    /// row that the user can select with the keys and open with Return.
    @Test func aDeniedRowCanBeSelectedAndOpened() async throws {
        let (a, denied) = (try folder.package("a"), try folder.package("denied"))
        app.exists = { $0 != denied }
        app.recent = [a, denied]
        app.showStart()
        let model = try #require(app.start?.model)
        let window = try #require(app.start?.window)
        await model.rowsTask?.value
        #expect(model.rows.map(\.exists) == [true, false])
        #expect(model.selection == a, "the first row that exists is selected")
        await until("the list has the focus") {
            window.contentView?.layoutSubtreeIfNeeded()
            return window.firstResponder is NSTableView
        }

        window.sendEvent(key(.keyDown, "\u{F701}", code: 125, in: window))
        window.sendEvent(key(.keyUp, "\u{F701}", code: 125, in: window))
        await until(limit: .seconds(10), "the Down Arrow selects the Not found row") { model.selection == denied }
        let down = key(.keyDown, "\r", code: 36, in: window)
        if !window.performKeyEquivalent(with: down) { window.sendEvent(down) }
        window.sendEvent(key(.keyUp, "\r", code: 36, in: window))

        await until(limit: .seconds(10), "Return opens the Not found row") {
            app.windows[packageIdentity(denied)] != nil
        }
        await closeAll(app)
    }
}
