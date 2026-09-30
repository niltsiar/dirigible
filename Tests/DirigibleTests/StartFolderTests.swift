import AppKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Change… and the folder preference of the start window (decision 0027). An extension of
/// `StartWindowTests`, so these tests run serialized with the other start windows.
extension StartWindowTests {
    /// Change… writes the chosen folder to the preference, and the form takes the folder, its
    /// text, and its free name.
    @Test func changeWritesTheFolderPreference() async throws {
        let domain = "DirigibleTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let chosen = folder.url.appending(path: "Chosen", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        try Session.create(at: chosen.appending(path: "Episode 1.dirigible"), sampleRate: 48_000)
        let app = AppDelegate(recordings: nil, defaults: defaults, defaultFolder: sessions)
        app.nameFormat = { "Episode \($0)" }
        app.chooseFolder = { _, done in done(chosen) }
        app.showStartWindow()
        let model = try #require(app.start?.model)
        await model.scanTask?.value

        model.changeFolder()
        await model.scanTask?.value

        #expect(defaults.string(forKey: "session.folder") == chosen.path, "Change… writes the folder preference")
        #expect(model.folder == chosen)
        #expect(model.folderText.hasSuffix("› Chosen"), "the form shows the chosen folder")
        #expect(model.name == "Episode 2", "the free name comes from the chosen folder")
        await closeAll(app)
    }

    /// A cancelled Change… writes nothing and keeps the folder.
    @Test func aCancelledChangeKeepsTheFolder() async throws {
        let domain = "DirigibleTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let app = AppDelegate(recordings: nil, defaults: defaults, defaultFolder: sessions)
        app.chooseFolder = { _, done in done(nil) }
        app.showStartWindow()
        let model = try #require(app.start?.model)
        await model.scanTask?.value

        model.changeFolder()
        await model.scanTask?.value

        #expect(defaults.object(forKey: "session.folder") == nil, "a cancelled change writes no key")
        #expect(model.folder == sessions, "a cancelled change keeps the folder")
        await closeAll(app)
    }

    /// Criterion C22 (plan gate, item 1): the scan result of the old folder does not change the
    /// name or the text of the new folder.
    @Test func anOldScanLeavesTheNameOfTheNewFolder() async throws {
        let (old, new) = (
            folder.url.appending(path: "A", directoryHint: .isDirectory),
            folder.url.appending(path: "B", directoryHint: .isDirectory)
        )
        for made in [old, new] { try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true) }
        try Session.create(at: old.appending(path: "Episode 1.dirigible"), sampleRate: 48_000)
        let app = AppDelegate(recordings: nil, defaultFolder: old)
        let format: @Sendable (Int) -> String = { "Episode \($0)" }
        app.nameFormat = format
        app.chooseFolder = { _, done in done(new) }
        app.showStartWindow()
        let model = try #require(app.start?.model)
        await model.scanTask?.value
        #expect(model.name == "Episode 2")

        model.changeFolder()
        await model.scanTask?.value
        let text = model.folderText
        model.apply(scan: await scanFolder(old, format: format, exists: app.exists))

        #expect(model.name == "Episode 1", "a scan of another folder leaves the name")
        #expect(model.folderText == text, "a scan of another folder leaves the folder text")
        await closeAll(app)
    }
}
