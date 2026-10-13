import AppKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio
@testable import DirigibleCore

/// File > Remove Unused Files… (decision 0047, criterion C13 of run
/// 2026-10-12-remove-unused-files). The package has track t1 with a clip of f1 and a stray WAV
/// with a UUID name. A test that moves the file removes only the Trash URL of its report. The menu
/// item and the sheet on the screen are a manual check (run.md).
@Suite(.serialized) @MainActor struct RemoveUnusedFilesWindowTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)
    let stray = "stray-\(UUID().uuidString).wav"

    init() throws { folder = try TemporaryFolder() }

    /// A key window of the package; with `stray`, the stray WAV is in `Clips/`.
    func window(stray: Bool = true) async throws -> (SessionWindow, Studio, NSWindow) {
        let package = try await timelinePackage(in: folder.url, tracks: 1, seconds: 1, audio: true)
        if stray { try Data(count: 64).write(to: package.appending(path: "Clips/\(self.stray)")) }
        let (model, studio, window, _) = try await openLanes(app, package)
        return (model, studio, window)
    }

    func strayExists(_ studio: Studio) -> Bool {
        FileManager.default.fileExists(atPath: studio.url.appending(path: "Clips/\(stray)").path)
    }

    /// Opens the sheet and returns it.
    func sheet(_ model: SessionWindow, _ window: NSWindow) async throws -> NSWindow {
        model.removeUnusedFiles()
        await until("the sheet shows") { model.unusedFiles != nil && window.attachedSheet != nil }
        let sheet = try #require(window.attachedSheet)
        sheet.contentView?.layoutSubtreeIfNeeded()
        return sheet
    }

    func buttons(_ view: NSView?) -> [NSButton] {
        guard let view else { return [] }
        return (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
    }

    func press(_ characters: String, code: UInt16, in sheet: NSWindow) {
        let event = key(.keyDown, characters, code: code, in: sheet)
        if !sheet.performKeyEquivalent(with: event) { sheet.sendEvent(event) }
    }

    /// C13: on with an idle key window, also with the focus in a text field; off with no window
    /// and while the studio is busy.
    @Test func menuItemState() async throws {
        #expect(!app.canRemoveUnusedFiles, "no window")
        let (model, studio, window) = try await window()
        #expect(app.canRemoveUnusedFiles, "an idle key window")
        _ = try await focusName(in: window)
        #expect(app.canRemoveUnusedFiles, "the focus in a text field")
        studio.transport = .recording(take: 1)
        #expect(!app.canRemoveUnusedFiles, "a take runs")
        studio.transport = .idle
        await model.close()
    }

    /// C13: Return gives Cancel, and Move to Trash has no key.
    @Test func returnCancels() async throws {
        let (model, studio, window) = try await window()
        let sheet = try await sheet(model, window)
        #expect(buttons(sheet.contentView).map(\.keyEquivalent).sorted() == ["", "\r", "\u{1b}"], "\(sheet)")

        press("\r", code: 36, in: sheet)

        await until("Return closes the sheet") { model.unusedFiles == nil && window.attachedSheet == nil }
        #expect(strayExists(studio) && model.pruneReport == nil)
        await model.close()
    }

    /// C13 negative: Escape cancels and moves nothing.
    @Test func cancelMovesNothing() async throws {
        let (model, studio, window) = try await window()
        let sheet = try await sheet(model, window)
        let xml = try Data(contentsOf: studio.url.appending(path: "session.xml"))

        press("\u{1b}", code: 53, in: sheet)

        await until("Escape closes the sheet") { model.unusedFiles == nil && window.attachedSheet == nil }
        #expect(strayExists(studio) && model.pruneReport == nil)
        #expect(try Data(contentsOf: studio.url.appending(path: "session.xml")) == xml)
        await model.close()
    }

    /// C13: Move to Trash moves the file, and a banner gives the count and the size.
    @Test func confirmMovesAndShowsBanner() async throws {
        let (model, studio, window) = try await window()
        let sheet = try await sheet(model, window)
        let move = try #require(buttons(sheet.contentView).first { $0.keyEquivalent == "" })

        move.performClick(nil)

        await until(limit: .seconds(10), "the prune ends") { model.pruneReport != nil }
        let report = try #require(model.pruneReport?.report)
        defer { for moved in report.moved { try? FileManager.default.removeItem(at: moved.trashURL) } }
        #expect(report.moved.map(\.item.path) == [stray] && !strayExists(studio))
        let banner = WindowBanner.unusedFilesMoved(count: 1, bytes: 64)
        await until("the banner shows") { model.shown.banners.contains(banner) }
        #expect(banner.kind == .info && banner.text == L10n.bannerUnusedMoved.format(1, L10n.bytes(64)))
        await model.close()
    }

    /// C13: with no file to move, an alert says so and no sheet opens.
    @Test func noUnusedFileShowsAlert() async throws {
        let (model, _, _) = try await window(stray: false)

        model.removeUnusedFiles()

        await until("the alert shows") { model.alert != nil }
        #expect(model.alert == .noUnusedFiles(UnusedFiles.Kept(count: 0, bytes: 0)) && model.unusedFiles == nil)
        #expect(model.alert?.text == L10n.alertUnusedNone.text, "no kept line with no kept file")
        model.alert = nil
        await model.close()
    }

    /// Review item 7: Move to Trash on a studio that became busy says so and moves nothing.
    @Test func busyMoveShowsAlert() async throws {
        let (model, studio, window) = try await window()
        let sheet = try await sheet(model, window)
        let move = try #require(buttons(sheet.contentView).first { $0.keyEquivalent == "" })
        studio.transport = .leveling

        move.performClick(nil)

        await until("the alert shows") { model.alert != nil }
        #expect(model.alert == .error(.busy) && strayExists(studio))
        studio.transport = .idle
        model.alert = nil
        await model.close()
    }

    /// Review item 11: the sheet names each damaged backup that keeps no file, as the CLI does.
    @Test func damagedLineNamesBackups() {
        let backups = [TimeInterval(2_000_000_000), 2_000_000_060].map {
            Backup(saved: Date(timeIntervalSince1970: $0))
        }
        let titles = backups.map { backupTitle($0.saved) }.joined(separator: ", ")

        #expect(L10n.damagedLine([]) == nil)
        #expect(L10n.damagedLine(backups) == L10n.sheetUnusedDamaged.format(titles))
    }
}
