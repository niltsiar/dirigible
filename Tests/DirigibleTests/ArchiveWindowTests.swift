import AppKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio
@testable import DirigibleCore

/// Holds the first block of a package job until `release`.
final class ArchiveHold: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var held = false

    var isHeld: Bool { lock.withLock { held } }

    func step() {
        let hold = lock.withLock {
            defer { held = true }
            return !held
        }
        if hold { semaphore.wait() }
    }

    func release() { semaphore.signal() }
}

/// The archive in the app (decision 0072, criteria C8 and C20 of run 2026-11-04-flac-archive). The
/// package has track t1 with a clip of f1, a 24-bit integer WAV (`ClipWriter`). The fixture with
/// `second` adds the unused pool file f2, so a Cancel after the first file leaves a mixed state.
@Suite(.serialized) @MainActor struct ArchiveWindowTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws { folder = try TemporaryFolder() }

    func window(archived: Bool, second: Bool = false) async throws -> (SessionWindow, Studio, NSWindow) {
        let package = try await timelinePackage(in: folder.url, tracks: 1, seconds: 1, audio: true)
        let (model, studio, window, _) = try await openLanes(app, package)
        if second {
            try FileManager.default.copyItem(
                at: package.appending(path: "Clips/f1.wav"), to: package.appending(path: "Clips/f2.wav"))
            try studio.edit(ripple: false) { (session: inout Session) throws(SessionError) in
                try session.addFile(AudioFile(id: "f2", path: "f2.wav", layout: .mono, length: 48_000))
            }
        }
        if archived { _ = try await studio.archive { _ in } }
        return (model, studio, window)
    }

    func clipNames(_ studio: Studio) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: studio.url.appending(path: "Clips").path)
            .filter { !$0.hasPrefix(".") }.sorted()
    }

    func buttons(_ view: NSView?) -> [NSButton] {
        guard let view else { return [] }
        return (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
    }

    /// Presses the button of the confirm sheet with `title`.
    func press(_ title: L10n, in window: NSWindow) async throws {
        await until("the confirm sheet shows") { window.attachedSheet != nil }
        let sheet = try #require(window.attachedSheet)
        try #require(buttons(sheet.contentView).first { $0.title == title.text }).performClick(nil)
        await until("the confirm sheet closes") { window.attachedSheet == nil }
    }

    /// C8: Add Marker by the menu on an archived window shows the progress sheet, then adds the
    /// marker once after the unarchive: `Clips/` has the WAV and no FLAC, and the banner goes.
    @Test func anEditOnAnArchivedWindowUnarchivesFirst() async throws {
        let (model, studio, window) = try await window(archived: true)
        #expect(try clipNames(studio) == ["f1.flac"])
        let hold = ArchiveHold()
        studio.environment.archiveBlock = { hold.step() }

        app.timeline(.addMarker, event: nil, in: window)

        await until("the unarchive holds") { hold.isHeld }
        #expect(studio.archiveRun?.kind == .unarchive && studio.session.markers.isEmpty)
        await until("the progress sheet shows") { window.attachedSheet != nil }
        hold.release()
        await until("the marker is in the session") { studio.session.markers.count == 1 }
        #expect(!studio.isArchived)
        #expect(try clipNames(studio) == ["f1.wav"])
        await until("the archived banner goes") { !model.shown.banners.contains { $0.key == "archived" } }
        await model.close()
    }

    /// C8 negative control: a working window adds the marker with no package job.
    @Test func aWorkingWindowEditsWithNoSheet() async throws {
        let (model, studio, window) = try await window(archived: false)

        app.timeline(.addMarker, event: nil, in: window)

        #expect(studio.session.markers.count == 1 && studio.archiveRun == nil)
        #expect(!model.shown.banners.contains { $0.key == "archived" })
        #expect(!window.subtitle.contains(L10n.subtitleArchived.text))
        await model.close()
    }

    /// C8: Cancel during the sheet drops the edit, and the session stays archived (partly).
    @Test func cancelDuringTheSheetDropsTheEdit() async throws {
        let (model, studio, window) = try await window(archived: true, second: true)
        let hold = ArchiveHold()
        studio.environment.archiveBlock = { hold.step() }

        app.timeline(.addMarker, event: nil, in: window)
        await until("the unarchive holds") { hold.isHeld }
        model.cancelPackageJob()
        hold.release()

        await until("the unarchive ends") { studio.archiveRun == nil }
        #expect(studio.session.markers.isEmpty && studio.isArchived)
        #expect(try clipNames(studio).filter { $0.hasSuffix(".flac") }.count == 1)
        let part = String(format: L10n.subtitleArchivedPart.text, 1, 2)
        await until("the subtitle gives the mixed state") { window.subtitle.contains(part) }
        await model.close()
    }

    /// C8: Record runs the unarchive and starts no take.
    @Test func recordUnarchivesAndStartsNoTake() async throws {
        let (model, studio, _) = try await window(archived: true)

        model.run(.record)

        await until("the unarchive ends") { !studio.isArchived && studio.archiveRun == nil }
        #expect(studio.session.recording == nil && !model.isTakeRunning)
        await model.close()
    }

    /// C8: a direct `Studio.edit` on an archived window gets the archived alert.
    @Test func aDirectEditGetsTheArchivedAlert() async throws {
        let (model, studio, _) = try await window(archived: true)

        model.edit(ripple: false) { (session: inout Session) throws(SessionError) in
            try session.renameTrack(TrackID("t1"), to: "New")
        }

        #expect(model.alert == .error(.archived))
        #expect(studio.session.tracks.first?.name == "T1" && studio.isArchived)
        await model.close()
    }

    /// C8: Remove Unused Files on an archived window unarchives first, then scans.
    @Test func removeUnusedFilesUnarchivesFirst() async throws {
        let (model, studio, _) = try await window(archived: true)

        model.removeUnusedFiles()

        await until("the scan alert shows") {
            if case .noUnusedFiles = model.alert { true } else { false }
        }
        #expect(!studio.isArchived)
        #expect(try clipNames(studio) == ["f1.wav"])
        await model.close()
    }

    /// C8: with the unused pool entry f2, the scan runs after the unarchive, so the sheet lists
    /// `f2.wav` with the bytes of the WAV, not of its FLAC.
    @Test func removeUnusedFilesListsTheWAVOfTheUnarchive() async throws {
        let (model, studio, _) = try await window(archived: true, second: true)

        model.removeUnusedFiles()

        await until("the sheet lists the files") { model.unusedFiles != nil }
        let items = try #require(model.unusedFiles?.items)
        let wav = studio.url.appending(path: "Clips/f2.wav").path
        let bytes = try #require(try FileManager.default.attributesOfItem(atPath: wav)[.size] as? Int64)
        #expect(items.map(\.path) == ["f2.wav"] && items.map(\.bytes) == [bytes])
        #expect(try clipNames(studio) == ["f1.wav", "f2.wav"])
        model.unusedFiles = nil
        await model.close()
    }

    /// C8: Add Marker by its key (Command-Return) with the focus in the timeline unarchives first. A
    /// track name field takes the key (`markerKeysGoToAFocusedField`).
    @Test func addMarkerByItsKeyUnarchivesFirst() async throws {
        let (model, studio, window) = try await window(archived: true)

        app.timeline(.addMarker, event: returnKey(in: window), in: window)

        await until("the marker is in the session") { studio.session.markers.count == 1 }
        #expect(!studio.isArchived)
        #expect(try clipNames(studio) == ["f1.wav"])
        await model.close()
    }

    /// C20 negative control: Cancel of the confirm sheet changes no file and keeps the menu title.
    @Test func cancelOfTheConfirmSheetChangesNoFile() async throws {
        let (model, studio, window) = try await window(archived: false)

        model.toggleArchive()
        try await press(.alertCancel, in: window)

        #expect(try clipNames(studio) == ["f1.wav"])
        #expect(!studio.isArchived && model.archiveMenuTitle == .menuFileArchive)
        await model.close()
    }

    /// C20: Archive in the confirm sheet archives; then the menu item, the subtitle, the archived
    /// banner, and the result banner change.
    @Test func archiveFromTheMenuShowsTheState() async throws {
        let (model, studio, window) = try await window(archived: false)

        model.toggleArchive()
        try await press(.alertArchiveConfirm, in: window)

        await until("the archive ends") { studio.isArchived && studio.archiveRun == nil }
        #expect(try clipNames(studio) == ["f1.flac"])
        #expect(model.archiveMenuTitle == .menuFileUnarchive)
        await until("the subtitle says archived") { window.subtitle.contains(L10n.subtitleArchived.text) }
        let keys = model.shown.banners.map(\.key)
        #expect(keys.contains("archived") && keys.contains("archiveSaved"), "\(keys)")
        await model.close()
    }

    /// C20 (d): Unarchive refuses at the need minus 1 with an alert that names both numbers, and runs
    /// at the need.
    @Test func unarchiveRefusesUnderTheNeed() async throws {
        let (model, studio, _) = try await window(archived: true)
        studio.environment.freeBytes = { _ in 0 }
        model.toggleArchive()
        await until("the refusal shows") { model.alert != nil }
        guard case .error(.archive(.space(let need, 0))) = model.alert else {
            Issue.record("no space refusal: \(String(describing: model.alert))")
            return
        }
        model.alert = nil

        studio.environment.freeBytes = { _ in need - 1 }
        model.toggleArchive()
        await until("the refusal shows") { model.alert != nil }
        #expect(model.alert == .error(.archive(.space(need: need, free: need - 1))))
        #expect(studio.isArchived)
        #expect(try clipNames(studio) == ["f1.flac"])
        model.alert = nil

        studio.environment.freeBytes = { _ in need }
        model.toggleArchive()
        await until("the unarchive ends") { !studio.isArchived && studio.archiveRun == nil }
        #expect(model.alert == nil)
        await model.close()
    }
}
