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

        #expect(app.start == nil)
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

    /// The action of a double-click: the session opens and the start window closes. A missing row
    /// opens nothing.
    @Test func openingARowOpensItsSessionAndClosesTheStartWindow() async throws {
        let a = try folder.package("a")
        app.recent = [missing, a]
        app.showStart()
        let model = try #require(app.start?.model)
        await model.rowsTask?.value

        await model.open(missing)
        #expect(app.windows.isEmpty, "a missing row opens nothing")
        #expect(app.start != nil)
        await model.open(a)

        #expect(app.windows[packageIdentity(a)] != nil, "a row opens its session")
        #expect(app.start == nil, "a row open closes the start window")
        await closeAll(app)
    }
}
