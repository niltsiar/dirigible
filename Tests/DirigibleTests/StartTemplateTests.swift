import AppKit
import DirigibleAudio
import DirigibleCore
import Foundation
import SwiftUI
import Testing
import os

@testable import DirigibleApp
@testable import DirigibleAudio

/// The Template pop-up of the New Session form and a create from a template (decision 0079, T9,
/// T15, T19). An extension of `StartWindowTests`, so these tests run serialized with the other start
/// windows.
extension StartWindowTests {
    var templates: URL { sessions.appending(path: "Templates") }

    /// An app with its own preferences, so a stored template does not leak into another test.
    func appWithDefaults() -> (AppDelegate, UserDefaults, String) {
        let suite = "DirigibleTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let app = AppDelegate(recordings: nil, defaults: defaults, defaultFolder: sessions)
        app.nameFormat = { "Episode \($0)" }
        return (app, defaults, suite)
    }

    /// A template package `name` in `Templates/` with `tracks` tracks.
    @discardableResult
    func makeTemplate(_ name: String, tracks: Int = 2, files: Int = 1) async throws -> URL {
        let stage = try TemporaryFolder(in: folder.url)
        let made = try await timelinePackage(in: stage.url, tracks: tracks, seconds: 1, audio: true)
        try FileManager.default.createDirectory(at: templates, withIntermediateDirectories: true)
        let target = templates.appending(path: "\(name).dirigible")
        try FileManager.default.moveItem(at: made, to: target)
        if files == 2 {
            // A second pool file on track t1, so a copy has a file after the first one.
            let clips = target.appending(path: "Clips")
            try FileManager.default.copyItem(at: clips.appending(path: "f1.wav"), to: clips.appending(path: "f2.wav"))
            var session = try Session(contentsOf: target)
            try session.addFile(AudioFile(id: "f2", path: "f2.wav", layout: .mono, length: 48_000))
            try session.place(Clip(id: ClipID("c-f2"), file: "f2", start: 96_000, offset: 0, length: 48_000), on: "t1")
            try session.write(to: target)
        }
        return target
    }

    func startModel(_ app: AppDelegate) async throws -> StartModel {
        app.showStart()
        let model = try #require(app.start?.model)
        await model.scanTask?.value
        await model.templatesTask?.value
        return model
    }

    /// The window of `model` with its real view at the size of the start window.
    func hosted(_ model: StartModel) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 420), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: StartView(model: model))
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    func controls(in view: NSView) -> [NSView] {
        view.subviews.flatMap { sub in
            ((sub is NSButton || sub is NSPopUpButton || sub is NSProgressIndicator) ? [sub] : []) + controls(in: sub)
        }
    }

    /// T9: None, then each template by name, in that order; the pop-up reads the folder at each show, so a
    /// template that the user saved later is in it.
    @Test func thePopUpListsNoneAndTheTemplates() async throws {
        let (app, _, _) = appWithDefaults()
        let (b, a) = (try await makeTemplate("Bravo"), try await makeTemplate("Alpha"))
        let model = try await startModel(app)

        #expect(model.templateChoices == [.none, .template(a), .template(b), .showInFinder])
        #expect(model.template == nil, "the first show has no choice")

        let c = try await makeTemplate("Charlie")
        app.showStart()
        await model.templatesTask?.value

        #expect(model.templateChoices == [.none, .template(a), .template(b), .template(c), .showInFinder])
        await closeAll(app)
    }

    /// T15: with no template, the form has no Template row at all.
    @Test func thePopUpIsHiddenWithNoTemplate() async throws {
        let (app, _, _) = appWithDefaults()
        let model = try await startModel(app)

        #expect(!model.showsTemplates && model.templateChoices.isEmpty)
        let window = hosted(model)
        #expect(controls(in: try #require(window.contentView)).allSatisfy { !($0 is NSPopUpButton) })
        window.close()
        await closeAll(app)
    }

    /// T15: the last item opens the Templates folder and keeps the choice.
    @Test func theLastItemShowsTemplatesInFinder() async throws {
        let (app, _, _) = appWithDefaults()
        let a = try await makeTemplate("Alpha")
        var opened: [URL] = []
        app.openURL = { opened.append($0) }
        let model = try await startModel(app)
        model.choose(.template(a))

        model.choose(.showInFinder)

        #expect(opened == [templates], "the item opens the Templates folder")
        #expect(model.template == a, "the choice is the same before and after")
        await closeAll(app)
    }

    /// T15: with the row, each control lies inside the 700 by 420 window. A title that wraps in a language
    /// takes one more line, so the check adds that line for each of the eight tables.
    @Test(arguments: ["de", "en", "es", "fr", "it", "nl", "pt", "pt-PT"])
    func theFormWithThePopUpFitsTheStartWindow(language: String) async throws {
        let (app, _, _) = appWithDefaults()
        try await makeTemplate("Alpha")
        let model = try await startModel(app)
        let window = hosted(model)
        let content = try #require(window.contentView)
        let all = controls(in: content)
        try #require(all.contains { $0 is NSPopUpButton }, "the form has the pop-up")

        let font = NSFont.systemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .largeTitle).pointSize, weight: .semibold)
        let title = try stringsTable(language)["start.title"] ?? ""
        let width = (title as NSString).size(withAttributes: [.font: font]).width
        // The welcome column is 420 wide with 28 of padding on each side.
        let lines = Int((width / 364).rounded(.up))
        let extra = Double(max(0, min(lines, 2) - 1)) * font.boundingRectForFont.height

        for control in all {
            let frame = content.convert(control.bounds, from: control)
            // Only the welcome column (the left 420 pt) has the title.
            let more = frame.minX < 420 ? extra : 0
            #expect(
                frame.minX >= 0 && frame.maxX <= 700 && frame.minY >= 0 && frame.maxY + more <= 420,
                "\(language): \(type(of: control)) at \(frame) with \(more) pt for the title")
        }
        window.close()
        await closeAll(app)
    }

    /// T9: Create with a template opens a session with its tracks.
    @Test func createWithATemplateOpensItsTracks() async throws {
        let (app, _, _) = appWithDefaults()
        let a = try await makeTemplate("Alpha", tracks: 2)
        let model = try await startModel(app)
        model.choose(.template(a))
        model.edit("Ep")

        model.create()
        await model.createTask?.value

        let url = sessions.appending(path: "Ep.dirigible")
        #expect(
            try Session(contentsOf: url).tracks.map(\.id.rawValue) == ["t1", "t2"], "the new package has the tracks")
        #expect(app.windows[packageIdentity(url)] != nil, "Create opens the session window")
        #expect(app.start == nil)
        await closeAll(app)
    }

    /// T9: the choice is in `session.template` and comes back at the next show.
    @Test func theLastTemplateComesBack() async throws {
        let (app, defaults, suite) = appWithDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        try await makeTemplate("Alpha")
        let b = try await makeTemplate("Bravo")
        var model = try await startModel(app)
        model.choose(.template(b))
        #expect(defaults.string(forKey: "session.template") == b.path)
        await closeAll(app)

        model = try await startModel(app)

        #expect(model.template == b, "the second show has the last choice")
        model.choose(.none)
        #expect(model.template == nil && defaults.string(forKey: "session.template") == nil, "None clears the choice")
        await closeAll(app)
    }

    /// T9: a stored template that is gone shows None.
    @Test func aGoneTemplateShowsNone() async throws {
        let (app, defaults, suite) = appWithDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = try await makeTemplate("Alpha")
        defaults.set(templates.appending(path: "Gone.dirigible").path, forKey: "session.template")
        var model = try await startModel(app)
        #expect(model.template == nil, "a template that is gone shows None")
        await closeAll(app)

        defaults.set(a.path, forKey: "session.template")
        model = try await startModel(app)
        #expect(model.template == a, "a template that is there shows")
        await closeAll(app)
    }

    /// T9: with a template, a name of 193 bytes keeps Create on and 194 turns it off. The bytes are
    /// those of the URL component, which is decomposed: "é" is 3 bytes there, 2 typed.
    @Test func aLongNameWithATemplateTurnsCreateOff() async throws {
        let (app, _, _) = appWithDefaults()
        let a = try await makeTemplate("Alpha")
        let model = try await startModel(app)

        model.edit(String(repeating: "a", count: 194))
        #expect(model.refusal == nil, "without a template the limit is 245 bytes")
        model.choose(.template(a))
        #expect(model.refusal == .long, "194 bytes turn Create off")
        model.edit(String(repeating: "a", count: 193))
        #expect(model.refusal == nil, "193 bytes keep Create on")
        let composed = String(repeating: "\u{e9}", count: 96) + "a"
        #expect(composed.utf8.count == 193, "the typed string has 193 bytes")
        model.edit(composed)
        #expect(model.refusal == .long, "the URL component has more bytes: Create is off")
        model.edit("\u{e9}\u{e9}")
        #expect(model.refusal == nil)
        await closeAll(app)
    }

    /// The push buttons of the view: SwiftUI draws their text, so a test counts them. A pop-up is no push button.
    func pushButtons(in view: NSView) -> [NSButton] {
        controls(in: view).compactMap { $0 as? NSButton }.filter { !($0 is NSPopUpButton) }
    }

    /// T18: the start window has no control to rename or delete a template: its push buttons are Change, Create, and
    /// Open Other, and the pop-up is the one control of the templates.
    @Test func theStartWindowHasNoRenameOrDelete() async throws {
        let (app, _, _) = appWithDefaults()
        try await makeTemplate("Alpha")
        let model = try await startModel(app)
        let window = hosted(model)
        let content = try #require(window.contentView)

        #expect(pushButtons(in: content).count == 3, "Change, Create, and Open Other")
        #expect(controls(in: content).filter { $0 is NSPopUpButton }.count == 1, "the pop-up")
        window.close()
        await closeAll(app)
    }

    /// A copy that waits in its first file.
    final class CopyHold: Sendable {
        private let entered = OSAllocatedUnfairLock(initialState: false)
        private let gate = DispatchSemaphore(value: 0)
        var isHeld: Bool { entered.withLock { $0 } }
        func hold() {
            entered.withLock { $0 = true }
            gate.wait()
            gate.signal()
        }
        func release() { gate.signal() }
    }

    /// T19: while the copy runs, the form has a bar and an enabled Cancel.
    @Test func aTemplateCreateShowsProgressAndCancel() async throws {
        let (app, _, _) = appWithDefaults()
        let a = try await makeTemplate("Alpha", files: 2)
        let hold = CopyHold()
        app.copyJobs.beforeCopy = { _ in hold.hold() }
        let model = try await startModel(app)
        model.choose(.template(a))
        model.edit("Ep")
        let idle = hosted(model)
        #expect(controls(in: try #require(idle.contentView)).allSatisfy { !($0 is NSProgressIndicator) })
        idle.close()

        model.create()
        await until("the copy holds in its first file") { hold.isHeld }

        #expect(model.createProgress != nil && model.canCancelCreate, "a bar and Cancel while the copy runs")
        let window = hosted(model)
        let all = controls(in: try #require(window.contentView))
        #expect(all.contains { $0 is NSProgressIndicator }, "the form shows a bar")
        let pushed = pushButtons(in: try #require(window.contentView))
        #expect(pushed.filter(\.isEnabled).count == 1, "Cancel is the one button that is on")
        window.close()
        hold.release()
        await model.createTask?.value
        #expect(model.createProgress == nil, "the bar goes with the copy")
        await closeAll(app)
    }

    /// T19: Cancel ends the copy; no package, no window, no alert, and the form shows again.
    @Test func cancelOfATemplateCreateMakesNothing() async throws {
        let (app, _, _) = appWithDefaults()
        let a = try await makeTemplate("Alpha", files: 2)
        var errors: [StudioError] = []
        app.showError = { errors.append($0) }
        let hold = CopyHold()
        app.copyJobs.beforeCopy = { _ in hold.hold() }
        let model = try await startModel(app)
        model.choose(.template(a))
        model.edit("Ep")
        model.create()
        await until("the copy holds in its first file") { hold.isHeld }

        model.cancelCreate()
        hold.release()
        await model.createTask?.value

        let names = try FileManager.default.contentsOfDirectory(atPath: sessions.path).sorted()
        #expect(names == ["Templates"], "no package, staging folder, or lock file: \(names)")
        #expect(app.windows.isEmpty, "no window opens")
        #expect(app.start?.window?.isVisible == true && !model.creating, "the form shows again")
        #expect(errors.isEmpty, "a cancel shows no alert")
        await closeAll(app)
    }

    /// A take ends the copy as `exportEnd` and the take disk check do: the start window shows the alert.
    @Test func aTakeStopOfATemplateCreateShowsAnAlert() async throws {
        let (app, _, _) = appWithDefaults()
        let a = try await makeTemplate("Alpha", files: 2)
        var errors: [StudioError] = []
        app.showError = { errors.append($0) }
        let hold = CopyHold()
        app.copyJobs.beforeCopy = { _ in hold.hold() }
        let model = try await startModel(app)
        model.choose(.template(a))
        model.edit("Ep")
        model.create()
        await until("the copy holds in its first file") { hold.isHeld }
        let job = try #require(app.copyJobs.jobs.first)

        let end = Task { await job.end() }
        await until("the take end sets the cancel flag") { job.task.isCancelled }
        hold.release()
        await end.value
        await model.createTask?.value

        #expect(errors == [.templateYielded], "a take stop shows its alert")
        #expect(app.windows.isEmpty && !model.creating, "no window opens, and the form shows again")
        await closeAll(app)
    }

    /// Code gate 1, item 8: a pick that comes while the rescan runs is the choice that stays, also None.
    @Test func aPickDuringARescanWins() async throws {
        let (app, _, _) = appWithDefaults()
        let a = try await makeTemplate("Alpha")
        let b = try await makeTemplate("Bravo")
        let model = try await startModel(app)
        model.choose(.template(a))

        model.scanTemplates()
        model.choose(.template(b))
        await model.templatesTask?.value
        #expect(model.template == b, "the pick of Bravo stays")

        model.scanTemplates()
        model.choose(.none)
        await model.templatesTask?.value
        #expect(model.template == nil, "the pick of None stays")
        await closeAll(app)
    }

    /// Code gate 1, item 5: a progress hop that comes after its create ended changes nothing, also while the
    /// next create runs. A bar left on screen would keep the form on the bar with Cancel off.
    @Test func aLateProgressHopOfAnEndedCreateChangesNothing() async throws {
        let (app, _, _) = appWithDefaults()
        let a = try await makeTemplate("Alpha", files: 2)
        let first = CopyHold()
        app.copyJobs.beforeCopy = { _ in first.hold() }
        let model = try await startModel(app)
        model.choose(.template(a))
        model.edit("Ep")
        model.create()
        await until("the first copy holds in its first file") { first.isHeld }
        let ended = model.createNumber
        model.cancelCreate()
        first.release()
        await model.createTask?.value
        try #require(model.createProgress == nil && !model.creating, "the first create ended")

        model.createProgressed(ended, 0.5)

        #expect(model.createProgress == nil, "a hop of an ended create sets no bar")
        let second = CopyHold()
        app.copyJobs.beforeCopy = { _ in second.hold() }
        model.create()
        await until("the second copy holds in its first file") { second.isHeld }
        try #require(model.createNumber != ended && model.createProgress == 0, "the second create has its own bar")

        model.createProgressed(ended, 0.9)

        #expect(model.createProgress == 0, "a hop of the first create does not move the bar of the second")
        model.cancelCreate()
        second.release()
        await model.createTask?.value
        await closeAll(app)
    }
}
