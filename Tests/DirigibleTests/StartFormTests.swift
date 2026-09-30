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

        #expect(!NSApp.windows.contains { $0 is NSSavePanel }, "New Session shows no save panel")
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

    /// Criterion C9: the first free name, then Create makes the package, opens its window, and
    /// closes the start window.
    @Test func createUsesTheFirstFreeNameAndOpensTheWindow() async throws {
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try Session.create(at: sessions.appending(path: "Episode 1.dirigible"), sampleRate: 48_000)
        try Session.create(at: sessions.appending(path: "Episode 3.dirigible"), sampleRate: 48_000)
        app.nameFormat = { "Episode \($0)" }
        app.showStartWindow()
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
        app.showStartWindow()
        let model = try #require(app.start?.model)
        await model.scanTask?.value

        #expect(model.name == "Episode 1", "an empty folder gives Episode 1")
        await closeAll(app)
    }

    /// A scan result after a user edit keeps the typed name. The folder text shows that the
    /// result came.
    @Test func aTypedNameIsNotReplacedByTheFreeName() async throws {
        app.nameFormat = { "Episode \($0)" }
        app.showStartWindow()
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
        app.showStartWindow()
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
        app.showStartWindow()
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
        app.showStartWindow()
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
        app.showStartWindow()
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

    /// Criterion C21 (plan gate, item 5): the folder preference counts only as an absolute path.
    @Test(arguments: [("", false), ("relative", false), ("<temp>/Podcasts", true)])
    func aBadFolderPreferenceGivesTheDefaultFolder(value: String, absolute: Bool) async throws {
        let domain = "DirigibleTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let stored = value.replacingOccurrences(of: "<temp>", with: folder.url.path)
        defaults.set(stored, forKey: "session.folder")
        let app = AppDelegate(recordings: nil, defaults: defaults, defaultFolder: sessions)

        app.showStartWindow()

        #expect(
            app.start?.model.folder.path == (absolute ? stored : sessions.path),
            "the folder preference is an absolute path or the default")
        await app.start?.model.scanTask?.value
        await closeAll(app)
    }
}

/// The field editor of the name field when it has the focus.
@MainActor func nameEditor(in window: NSWindow) -> NSTextView? {
    window.contentView?.layoutSubtreeIfNeeded()
    guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor, editor.delegate is NSTextField
    else { return nil }
    return editor
}
