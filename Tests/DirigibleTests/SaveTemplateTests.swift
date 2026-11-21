import AppKit
import DirigibleAudio
import DirigibleCore
import Foundation
import SwiftUI
import Testing
import os

@testable import DirigibleApp
@testable import DirigibleAudio

/// File > Save as Template... and File > Show Templates in Finder on a real session window
/// (decision 0079, T7, T10, T12, T16, T17, T18). The sheets and the Trash call are stubs that keep
/// their answer, as a panel does.
@Suite(.serialized) @MainActor struct SaveTemplateTests {
    /// What the stubs saw and what they answer.
    @MainActor final class Panels {
        var name: String?
        var lines: [String] = []
        var replace = false
        var replaceAsked: [String] = []
        var opened: [URL] = []
    }

    let folder: TemporaryFolder
    let app: AppDelegate
    let panels = Panels()
    /// The Trash call runs off the main actor.
    let trashFails = OSAllocatedUnfairLock(initialState: false)
    let defaults: UserDefaults
    let suite = "DirigibleTests-\(UUID().uuidString)"
    var sessions: URL { folder.url.appending(path: "Music/Dirigible") }
    var templates: URL { sessions.appending(path: "Templates") }
    var trash: URL { folder.url.appending(path: "Trash") }

    init() throws {
        NSWindow.allowsAutomaticWindowTabbing = false
        folder = try TemporaryFolder()
        defaults = UserDefaults(suiteName: suite)!
        app = AppDelegate(
            recordings: nil, defaults: defaults, defaultFolder: folder.url.appending(path: "Music/Dirigible"))
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let (panels, trash, trashFails) = (panels, trash, trashFails)
        app.templatePanels.chooseName = { _, line, done in
            panels.lines.append(line)
            done(panels.name)
        }
        app.templatePanels.confirmReplace = { _, name, done in
            panels.replaceAsked.append(name)
            done(panels.replace)
        }
        app.templatePanels.trash = { url in
            if trashFails.withLock({ $0 }) { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.moveItem(at: url, to: trash.appending(path: url.lastPathComponent))
        }
        app.openURL = { panels.opened.append($0) }
    }

    func window(tracks: Int = 3, seconds: Int = 1) async throws -> (SessionWindow, Studio) {
        let package = try await timelinePackage(in: folder.url, tracks: tracks, seconds: seconds, audio: true)
        let model = await app.open(package)
        let studio = try #require(await model.opened() ? model.studio : nil)
        return (model, studio)
    }

    func templateTracks(_ name: String) throws -> [String] {
        try Session(contentsOf: templates.appending(path: "\(name).dirigible")).tracks.map(\.id.rawValue)
    }

    func clean() { defaults.removePersistentDomain(forName: suite) }

    // MARK: T10

    /// T10: Save writes `Templates/<name>.dirigible` and makes `Templates/` in the default folder.
    @Test func saveAsTemplateWritesTheTemplateInTheDefaultFolder() async throws {
        defer { clean() }
        let (model, _) = try await window()
        panels.name = "Show"
        #expect(!FileManager.default.fileExists(atPath: templates.path))

        await model.saveAsTemplate()

        #expect(try templateTracks("Show") == ["t1", "t2", "t3"], "the template has the tracks of the window")
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: templates.path) == ["Show.dirigible"],
            "no staging folder or lock file")
        #expect(model.alert == nil)
        await model.close()
    }

    /// T10: the folder that the user chose for new sessions gets no `Templates/`.
    @Test func aChosenSessionFolderGetsNoTemplatesFolder() async throws {
        defer { clean() }
        let chosen = folder.url.appending(path: "Chosen")
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        defaults.set(chosen.path, forKey: AppDelegate.folderKey)
        let (model, _) = try await window()
        panels.name = "Show"

        await model.saveAsTemplate()

        #expect(try FileManager.default.contentsOfDirectory(atPath: chosen.path) == [], "the chosen folder is empty")
        #expect(try templateTracks("Show") == ["t1", "t2", "t3"])
        await model.close()
    }

    /// T10: a name that 0027 refuses, or over `templateNameLimit` in the bytes of the URL component, turns Save
    /// off.
    @Test func aRefusedNameTurnsSaveOff() {
        let sheet = TemplateNameSheet(keeps: "Keeps no clips.")
        let composed = String(repeating: "\u{e9}", count: 96) + "a"
        let cases: [(String, Bool)] = [
            ("", false), ("   ", false), ("a/b", false), ("a:b", false), (".hidden", false),
            ("Show", true), (String(repeating: "a", count: 193), true), (String(repeating: "a", count: 194), false),
            (composed, false), ("\u{e9}\u{e9}", true),
        ]
        for (name, on) in cases {
            sheet.field.stringValue = name
            sheet.nameChanged()
            #expect(sheet.saveButton.isEnabled == on, "Save for \(name.prefix(12)) (\(name.utf8.count) bytes)")
        }
    }

    /// T10: Show Templates in Finder opens the folder; with no `Templates/` yet it opens the default folder.
    @Test func showTemplatesInFinderOpensTheFolder() async throws {
        defer { clean() }
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        await app.showTemplatesInFinder()
        #expect(panels.opened == [sessions], "no Templates folder: the default folder")

        try FileManager.default.createDirectory(at: templates, withIntermediateDirectories: true)
        await app.showTemplatesInFinder()
        #expect(panels.opened == [sessions, templates])
    }

    // MARK: T16

    /// Sets the logical size of the pool file of the package to `bytes` (a sparse file).
    func resize(_ model: SessionWindow, to bytes: UInt64) throws {
        let handle = try FileHandle(forWritingTo: model.url.appending(path: "Clips/f1.wav"))
        try handle.truncate(atOffset: bytes)
        try handle.close()
    }

    func line(_ model: SessionWindow, _ studio: Studio) async throws -> String {
        let table = try stringsTable("en")
        let keeps = await templateKeeps(of: try studio.session.newEpisode(), in: model.url)
        return keeps.text(table: { table[$0.rawValue] ?? "" })
    }

    /// T16: the line has the clip count and the bytes of the files that the template keeps. An unused file of
    /// the pool does not add.
    @Test func theSheetLineHasTheClipCountAndTheSize() async throws {
        let (model, studio) = try await window(tracks: 12)
        try resize(model, to: 1_400_000_000)
        let unused = model.url.appending(path: "Clips/unused.wav")
        try Data().write(to: unused)
        let handle = try FileHandle(forWritingTo: unused)
        try handle.truncate(atOffset: 100_000_000)
        try handle.close()

        let line = try await line(model, studio)

        #expect(
            line
                == "Keeps 12 clips, \(ByteCountFormatter.string(fromByteCount: 1_400_000_000, countStyle: .file)) of audio."
        )
        #expect(!line.contains("1.5"), "the unused file adds no bytes")
        await model.close()
    }

    @Test func theSheetLineForOneClip() async throws {
        let (model, studio) = try await window(tracks: 1)
        try resize(model, to: 2_000_000)

        let line = try await line(model, studio)

        #expect(
            line == "Keeps 1 clip, \(ByteCountFormatter.string(fromByteCount: 2_000_000, countStyle: .file)) of audio.")
        await model.close()
    }

    @Test func theSheetLineForNoClip() async throws {
        let package = folder.url.appending(path: "empty.dirigible")
        try Session.create(at: package, sampleRate: 48_000)
        let model = await app.open(package)
        let studio = try #require(await model.opened() ? model.studio : nil)

        #expect(try await line(model, studio) == "Keeps no clips.")
        await model.close()
    }

    /// T16: one line under the name field and no check box.
    @Test func theSheetHasNoKeepClipsCheckBox() throws {
        let sheet = TemplateNameSheet(keeps: "Keeps 12 clips, 1.4 GB of audio.")
        func walk(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(walk) }
        let accessory = try #require(sheet.alert.accessoryView)
        let all = walk(accessory)

        #expect(all.compactMap { $0 as? NSButton }.isEmpty, "no check box in the accessory view")
        let lines = all.compactMap { ($0 as? NSTextField)?.stringValue }
        #expect(lines.contains("Keeps 12 clips, 1.4 GB of audio."), "the line is under the name field")
        #expect(sheet.alert.buttons.map(\.title) == [L10n.templateSaveButton.text, L10n.alertCancel.text])
    }

    // MARK: T17

    func existing(_ name: String, tracks: Int) async throws -> URL {
        try FileManager.default.createDirectory(at: templates, withIntermediateDirectories: true)
        let stage = try TemporaryFolder(in: folder.url)
        let made = try await timelinePackage(in: stage.url, tracks: tracks, seconds: 1, audio: true)
        let target = templates.appending(path: "\(name).dirigible")
        try FileManager.default.moveItem(at: made, to: target)
        return target
    }

    /// T17: the alert names the template, with Replace and Cancel; the save asks it for an existing name.
    @Test func anExistingNameShowsReplaceAndCancel() async throws {
        defer { clean() }
        _ = try await existing("Show", tracks: 1)
        let (model, _) = try await window()
        panels.name = "Show"

        await model.saveAsTemplate()

        #expect(panels.replaceAsked == ["Show"], "the alert is for the existing name")
        let alert = templateReplaceAlert(name: "Show")
        #expect(alert.messageText == L10n.templateReplaceTitle.format("Show"))
        #expect(alert.buttons.map(\.title) == [L10n.alertCancel.text, L10n.templateReplaceReplace.text])
        await model.close()
    }

    /// T17: Return runs Cancel.
    @Test func cancelIsTheDefaultButton() {
        let alert = templateReplaceAlert(name: "Show")
        #expect(alert.buttons[0].title == L10n.alertCancel.text)
        #expect(alert.buttons[0].keyEquivalent == "\r", "Return presses Cancel")
        #expect(alert.window.defaultButtonCell === alert.buttons[0].cell, "Cancel is the default")
        #expect(alert.buttons[1].hasDestructiveAction, "Replace is the destructive button")
    }

    /// T17: Cancel keeps the old template as it is.
    @Test func cancelKeepsTheOldTemplate() async throws {
        defer { clean() }
        let old = try await existing("Show", tracks: 1)
        let before = try Data(contentsOf: old.appending(path: "session.xml"))
        let (model, _) = try await window()
        panels.name = "Show"
        panels.replace = false

        await model.saveAsTemplate()

        #expect(try Data(contentsOf: old.appending(path: "session.xml")) == before, "the old template did not change")
        #expect(try templateTracks("Show") == ["t1"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: trash.path).isEmpty, "nothing went to the Trash")
        #expect(try FileManager.default.contentsOfDirectory(atPath: templates.path) == ["Show.dirigible"])
        await model.close()
    }

    /// T17: Replace moves the old package to the Trash, and the name holds the new one.
    @Test func replaceMovesTheOldTemplateToTheTrashAndSaves() async throws {
        defer { clean() }
        _ = try await existing("Show", tracks: 1)
        let (model, _) = try await window()
        panels.name = "Show"
        panels.replace = true

        await model.saveAsTemplate()

        let trashed = try FileManager.default.contentsOfDirectory(atPath: trash.path)
        #expect(trashed == ["Show.dirigible"], "the old package is in the Trash")
        #expect(
            try Session(contentsOf: trash.appending(path: "Show.dirigible")).tracks.map(\.id.rawValue) == ["t1"],
            "the Trash holds the old content")
        #expect(try templateTracks("Show") == ["t1", "t2", "t3"], "the name holds the new package")
        await model.close()
    }

    /// T17: a failed move saves nothing, and the old template stays.
    @Test func aFailedTrashMoveSavesNothing() async throws {
        defer { clean() }
        let old = try await existing("Show", tracks: 1)
        let before = try Data(contentsOf: old.appending(path: "session.xml"))
        let (model, _) = try await window()
        panels.name = "Show"
        panels.replace = true
        trashFails.withLock { $0 = true }

        await model.saveAsTemplate()

        #expect(try Data(contentsOf: old.appending(path: "session.xml")) == before, "the old template stays")
        #expect(model.alert == .templateTrash("Show"), "the window shows the error")
        #expect(try FileManager.default.contentsOfDirectory(atPath: templates.path) == ["Show.dirigible"])
        await model.close()
    }

    // MARK: T18

    /// T18: the two items are a group of their own, and no Export item is between them.
    @Test func theTemplateItemsAreAGroupOfTheirOwn() {
        #expect(TemplateMenu.group.map(\.title) == [.menuFileSaveTemplate, .menuFileShowTemplates])
        let exports = TimelineCommand.fileItems.map(\.title)
        #expect(TemplateMenu.group.allSatisfy { !exports.contains($0.title) }, "the items are no Export item")
    }

    // MARK: T12 and T7

    /// T12: the text of a full disk has both sizes, as the Finder shows them.
    @Test func theFullDiskTextNamesBothNumbers() throws {
        let table = try stringsTable("en")
        let text = L10n.message(
            for: TemplateError.space(needed: 5_000_000_000, free: 1_000_000_000), table: { table[$0.rawValue] ?? "" })
        #expect(
            text.contains(ByteCountFormatter.string(fromByteCount: 5_000_000_000, countStyle: .file)),
            Comment(rawValue: text))
        #expect(
            text.contains(ByteCountFormatter.string(fromByteCount: 1_000_000_000, countStyle: .file)),
            Comment(rawValue: text))
    }

    /// T7: while the window saves a template, the progress sheet says so, and it says "Exporting" when it exports.
    @Test func theProgressSheetSaysItSavesATemplate() async throws {
        defer { clean() }
        let (model, studio) = try await window(tracks: 1, seconds: 40)
        studio.environment.templateCanClone = { _, _ in false }
        let held = OSAllocatedUnfairLock(initialState: false)
        let gate = DispatchSemaphore(value: 0)
        studio.environment.templateWritten = { _, _ in
            held.withLock { $0 = true }
            gate.wait()
            gate.signal()
        }
        panels.name = "Show"
        #expect(model.sheetTitle == exportSheetTitle(nil), "before a save, the sheet title is the export title")

        let save = Task { await model.saveAsTemplate() }
        await until("the copy holds in a write") { held.withLock { $0 } }

        #expect(model.sheetTitle == L10n.sheetTemplateTitle.text, "the sheet says that it saves a template")
        #expect(model.sheetTitle != exportSheetTitle(studio.exportFile))
        gate.signal()
        await save.value
        #expect(model.sheetTitle == exportSheetTitle(nil), "after the save, the title is the export title again")
        #expect(try templateTracks("Show") == ["t1"])
        await model.close()
    }
}
