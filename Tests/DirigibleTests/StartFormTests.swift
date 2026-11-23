import AppKit
import DirigibleCore
import Foundation
import Testing
import os

@testable import DirigibleApp
@testable import DirigibleAudio

/// The New Session form of the start window (decision 0027). An extension of `StartWindowTests`,
/// so these tests run serialized with the other start windows.
extension StartWindowTests {
    /// The default folder of `app`: `<temp>/Music/Dirigible`.
    var sessions: URL { folder.url.appending(path: "Music/Dirigible") }

    /// Criterion C8: Command-N shows the start window with the focus in the name field, also over
    /// a session window. No save panel shows.
    ///
    /// The test records the first responders of the window and ignores the window itself. The
    /// SwiftUI field editor is one object for all windows of the process. The marker rename alert
    /// of a parallel suite can take it after the focus came, and the window itself is then the
    /// first responder of the start window.
    @Test func newSessionShowsTheStartWindowAndNoSavePanel() async throws {
        await app.open(try folder.package("a"))

        app.newSession()

        #expect(!NSApp.windows.contains { $0 is NSSavePanel && $0.isVisible }, "New Session shows no save panel")
        let window = try #require(app.start?.window, "New Session shows the start window")
        let model = try #require(app.start?.model)
        #expect(window.isVisible)
        var last: NSResponder?
        let observation = window.observe(\.firstResponder, options: [.initial, .new]) { window, _ in
            MainActor.assumeIsolated { if window.firstResponder !== window { last = window.firstResponder } }
        }
        await model.rowsTask?.value
        #expect(model.focus == .name, "the recent rows keep the focus of New Session")
        // The field editor has no delegate yet when AppKit makes it the first responder. The start
        // window has one text field, the name field. The limit is 3 times the worst time to the
        // focus in the loaded full-suite runs (1.2 s), and at least 10 s.
        await until(limit: .seconds(10), "New Session puts the focus in the name field") {
            (last as? NSTextView)?.isFieldEditor == true
        }
        observation.invalidate()
        await closeAll(app)
    }

    /// Criterion C8: when the name field takes the focus from a show, its text is selected, so a
    /// typed key replaces it, as in a save panel. A new window gets the name from the folder scan
    /// after the field has the focus. A window that shows again keeps the caret of its field.
    @Test(arguments: [false, true])
    func aShowSelectsTheName(again: Bool) async throws {
        // The name of the product: the folder has no package, so the scan gives number 1.
        let name = app.nameFormat(1)
        let whole = NSRange(location: 0, length: (name as NSString).length)
        if again {
            app.showStart(focus: .name)
            let window = try #require(app.start?.window)
            await until(limit: .seconds(10), "the first show gives the name") {
                focusedNameEditor(in: window)?.string == name
            }
            nameEditor(in: window)?.setSelectedRange(NSRange(location: whole.length, length: 0))
        }

        app.newSession()

        let window = try #require(app.start?.window)
        await until(limit: .seconds(10), "the name field has the focus and the name") {
            focusedNameEditor(in: window)?.string == name
        }
        await until(limit: .seconds(10), "a show selects the whole name") {
            focusedNameEditor(in: window)?.selectedRange() == whole
        }
        let editor = try #require(nameEditor(in: window))
        editor.insertText("x", replacementRange: editor.selectedRange())
        #expect(app.start?.model.name == "x", "a typed key replaces the selected name")
        // The view calls nameShown() after the edit. An edit is not selected, so the next key adds
        // to it. The direct call has no await, so no other window can take the field editor.
        app.start?.model.nameShown()
        editor.insertText("y", replacementRange: editor.selectedRange())
        #expect(app.start?.model.name == "xy", "a typed key after an edit adds to the name")
        await closeAll(app)
    }

    /// Criterion C9: the first free name, then Create makes the package, opens its window, and
    /// closes the start window.
    @Test func createUsesTheFirstFreeNameAndOpensTheWindow() async throws {
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try Session.create(at: sessions.appending(path: "Episode 1.dirigible"), sampleRate: 48_000)
        try Session.create(at: sessions.appending(path: "Episode 3.dirigible"), sampleRate: 48_000)
        app.nameFormat = { "Episode \($0)" }
        app.showStart()
        let model = try #require(app.start?.model)
        await model.scanTask?.value

        #expect(model.name == "Episode 2", "the free name is Episode 2")
        model.create()
        await model.createTask?.value

        let url = sessions.appending(path: "Episode 2.dirigible")
        #expect((try? Session(contentsOf: url)) == Session(sampleRate: 48_000), "Create makes the package")
        #expect(app.windows[packageIdentity(url)] != nil, "Create opens the session window")
        #expect(app.start == nil, "Create closes the start window")
        await closeAll(app)
    }

    /// Criterion C9, the control: an empty folder gives the first number.
    @Test func anEmptyFolderGivesEpisode1() async throws {
        app.nameFormat = { "Episode \($0)" }
        app.showStart()
        let model = try #require(app.start?.model)
        await model.scanTask?.value

        #expect(model.name == "Episode 1", "an empty folder gives Episode 1")
        await closeAll(app)
    }

    /// A scan result after a user edit keeps the typed name. The folder text shows that the
    /// result came.
    @Test func aTypedNameIsNotReplacedByTheFreeName() async throws {
        app.nameFormat = { "Episode \($0)" }
        app.showStart()
        let model = try #require(app.start?.model)

        model.edit("My show")
        await model.scanTask?.value

        #expect(model.folderText == "Music › Dirigible")
        #expect(model.name == "My show", "a scan result keeps the typed name")
        await closeAll(app)
    }

    /// Criterion C10: the first Create in the default folder makes that folder, and a Create in a
    /// missing chosen folder makes nothing. Each file check runs off the main actor (plan gate,
    /// item 4).
    @Test(arguments: [false, true])
    func createMakesOnlyTheDefaultFolder(chosen: Bool) async throws {
        try FileManager.default.createDirectory(
            at: sessions.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Its parent exists, so a one-level make of the chosen folder would work.
        let gone = folder.url.appending(path: "gone", directoryHint: .isDirectory)
        let onMain = OSAllocatedUnfairLock(initialState: [Bool]())
        app.exists = { url in
            onMain.withLock { $0.append(Thread.isMainThread) }
            return FileManager.default.fileExists(atPath: url.path)
        }
        let errors = OSAllocatedUnfairLock(initialState: [StudioError]())
        app.showError = { error in errors.withLock { $0.append(error) } }
        app.chooseFolder = { _, done in done(gone) }
        app.nameFormat = { "Episode \($0)" }
        app.showStart()
        let model = try #require(app.start?.model)
        await model.scanTask?.value
        if chosen {
            model.changeFolder()
            await model.scanTask?.value
            model.edit("typed")
        }

        model.create()
        await model.createTask?.value

        if chosen {
            let missing = errors.withLock { $0 }.contains {
                if case .file(.writeFailed(_, let code)) = $0 { code == ENOENT } else { false }
            }
            #expect(missing, "a Create in a missing chosen folder fails with ENOENT")
            #expect(
                !FileManager.default.fileExists(atPath: folder.url.appending(path: "gone").path),
                "the app makes no chosen folder")
            #expect(app.start?.window?.isVisible == true)
            #expect(model.name == "typed", "a failed Create keeps the typed name")
        } else {
            #expect(FileManager.default.fileExists(atPath: sessions.appending(path: "Episode 1.dirigible").path))
        }
        let calls = onMain.withLock { $0 }
        #expect(!calls.isEmpty && !calls.contains(true), "a file check runs off the main actor")
        await closeAll(app)
    }

    /// Criterion C20: an error keeps the start window and the typed name, and a later Create
    /// works.
    @Test func aCreateErrorKeepsTheStartWindowAndTheName() async throws {
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try Session.create(at: sessions.appending(path: "a.dirigible"), sampleRate: 48_000)
        let errors = OSAllocatedUnfairLock(initialState: [StudioError]())
        app.showError = { error in errors.withLock { $0.append(error) } }
        app.showStart()
        let model = try #require(app.start?.model)
        await model.scanTask?.value

        model.edit("a")
        model.create()
        await model.createTask?.value

        #expect(errors.withLock { $0 } == [.file(.exists)])
        #expect(app.start?.window?.isVisible == true, "an error keeps the start window")
        #expect(model.name == "a", "an error keeps the typed name")
        model.edit("b")
        model.create()
        await model.createTask?.value
        #expect(
            FileManager.default.fileExists(atPath: sessions.appending(path: "b.dirigible").path),
            "a Create after an error makes the package")
        await closeAll(app)
    }

    /// Criterion C11: a refused name makes no package and no folder, shows its reason, and keeps
    /// the typed text.
    @Test func aRefusedNameCreatesNothingAndKeepsTheText() async throws {
        // The parent of the default folder, so a Create could make the default folder.
        try FileManager.default.createDirectory(
            at: sessions.deletingLastPathComponent(), withIntermediateDirectories: true)
        let errors = OSAllocatedUnfairLock(initialState: [StudioError]())
        app.showError = { error in errors.withLock { $0.append(error) } }
        app.showStart()
        let model = try #require(app.start?.model)
        await model.scanTask?.value

        model.edit("a/b")
        model.create()
        await model.createTask?.value

        #expect(model.refusal == .character, "the form shows the reason")
        #expect(!model.creating)
        #expect(!FileManager.default.fileExists(atPath: sessions.path), "a refused name makes no package")
        #expect(errors.withLock { $0 }.isEmpty)
        #expect(model.name == "a/b", "a refused name keeps the typed text")
        await closeAll(app)
    }

    /// Criterion C20 (plan gate, item 3): a second Create while one runs does nothing.
    @Test func twoCreatesMakeOnePackage() async throws {
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let errors = OSAllocatedUnfairLock(initialState: [StudioError]())
        app.showError = { error in errors.withLock { $0.append(error) } }
        app.nameFormat = { "Episode \($0)" }
        app.showStart()
        let model = try #require(app.start?.model)
        await model.scanTask?.value

        model.create()
        let first = model.createTask
        let creating = model.creating
        model.create()
        await first?.value
        await model.createTask?.value

        #expect(creating, "a Create sets the creating flag at once")
        #expect(FileManager.default.fileExists(atPath: sessions.appending(path: "Episode 1.dirigible").path))
        #expect(errors.withLock { $0 }.isEmpty, "a second Create while one runs gives no error")
        await closeAll(app)
    }

    /// Code gate 1, item 4: while a Create runs, a row open (a double-click or Return in the list)
    /// and a close of the start window do nothing. The typed name stays, and the Create goes on.
    @Test func aCreateRefusesARowOpenAndAClose() async throws {
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let a = try folder.package("a")
        app.recent = [a]
        app.showStart()
        let model = try #require(app.start?.model)
        let window = try #require(app.start?.window)
        await model.rowsTask?.value
        await model.scanTask?.value
        model.edit("typed")

        model.create()
        let creating = model.creating
        await model.open(a)
        window.performClose(nil)
        let shows = app.start != nil && window.isVisible
        let name = model.name
        await model.createTask?.value

        #expect(creating, "a Create sets the creating flag at once")
        #expect(app.windows[packageIdentity(a)] == nil, "a row open during a Create opens nothing")
        #expect(shows, "a close during a Create is refused")
        #expect(name == "typed", "a refused act keeps the typed name")
        let made = sessions.appending(path: "typed.dirigible")
        #expect(app.windows[packageIdentity(made)] != nil, "the Create goes on and opens its session")
        await closeAll(app)
    }

    /// Criterion C21 (plan gate, item 5): the folder preference counts only as an absolute path.
    @Test(arguments: [("", false), ("relative", false), ("<temp>/Podcasts", true)])
    func aBadFolderPreferenceGivesTheDefaultFolder(value: String, absolute: Bool) async throws {
        let domain = "DirigibleTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let stored = value.replacingOccurrences(of: "<temp>", with: folder.url.path)
        defaults.set(stored, forKey: "session.folder")
        let app = AppDelegate(recordings: nil, defaults: defaults, defaultFolder: sessions)

        app.showStart()

        #expect(
            app.start?.model.folder.path == (absolute ? stored : sessions.path),
            "the folder preference is an absolute path or the default")
        await app.start?.model.scanTask?.value
        await closeAll(app)
    }
}

/// The field editor of the name field. The SwiftUI field editor is one object for all windows of
/// the test process, and a text field in another window can take it (decisions.tsv
/// 2026-09-30T08:25). The start window is then its own first responder, and this function gives
/// the focus back to the name field. A fault in the product does not make that state.
@MainActor func focusedNameEditor(in window: NSWindow) -> NSTextView? {
    if window.firstResponder === window, let field = window.contentView.flatMap(firstEditableField) {
        window.makeFirstResponder(field)
    }
    return nameEditor(in: window)
}

/// The field editor of the name field when it has the focus.
@MainActor func nameEditor(in window: NSWindow) -> NSTextView? {
    window.contentView?.layoutSubtreeIfNeeded()
    guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor, editor.delegate is NSTextField
    else { return nil }
    return editor
}
