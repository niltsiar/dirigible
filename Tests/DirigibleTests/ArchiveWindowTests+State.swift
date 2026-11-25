import AVFoundation
import AppKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio
@testable import DirigibleCore

/// C10, C12, C16, and C20 of run 2026-11-04-flac-archive: the menu item, the keys of the progress
/// sheet, a partial state, and the result banners of a package job.
extension ArchiveWindowTests {
    /// Presses Archive in the confirm sheet and returns at once: the progress sheet can take the
    /// sheet slot before a wait for an empty slot reads it.
    func confirm(in window: NSWindow) async throws {
        await until("the confirm sheet shows") { window.attachedSheet != nil }
        let sheet = try #require(window.attachedSheet)
        try #require(buttons(sheet.contentView).first { $0.title == L10n.alertArchiveConfirm.text }).performClick(nil)
    }

    /// The report banner with `key` after the job.
    func reportBanner(_ key: String, _ model: SessionWindow, _ studio: Studio) -> WindowBanner? {
        ChromeState.reportBanners(model, studio).first { $0.key == key }
    }

    /// C20: the string table of each language gives Archive Session with U+2026, and Unarchive
    /// Session with none.
    @Test func theArchiveItemTitleEndsWithAnEllipsisInEachLanguage() throws {
        for language in AppLanguage.allCases.map(\.rawValue) {
            let table = try stringsTable(language)
            let title = try #require(table[L10n.menuFileArchive.rawValue], "\(language)")
            #expect(title.hasSuffix("\u{2026}") && !title.contains("..."), "\(language): \(title)")
            #expect(table[L10n.menuFileUnarchive.rawValue]?.contains("\u{2026}") == false, "\(language)")
        }
    }

    /// C20: during a take the archive item is off, and the command starts no job.
    @Test func theArchiveItemIsOffDuringATake() async throws {
        let (model, studio, window) = try await window(archived: false)
        #expect(app.canRemoveUnusedFiles, "an idle key window")
        studio.transport = .recording(take: 1)

        #expect(!app.canRemoveUnusedFiles, "a take runs")
        model.toggleArchive()
        await runLoopPass()

        #expect(window.attachedSheet == nil && studio.archiveRun == nil)
        studio.transport = .idle
        #expect(try clipNames(studio) == ["f1.wav"])
        await model.close()
    }

    /// C20: Esc and Command-period in the progress sheet stop the unarchive after the file in hand.
    @Test(arguments: [false, true])
    func aKeyInTheProgressSheetStopsTheJob(commandPeriod: Bool) async throws {
        let (model, studio, window) = try await window(archived: true, second: true)
        let hold = ArchiveHold()
        studio.environment.archiveBlock = { hold.step() }
        model.toggleArchive()
        await until("the unarchive holds") { hold.isHeld }
        await until("the progress sheet shows") { window.attachedSheet != nil }
        let sheet = try #require(window.attachedSheet)
        let event =
            commandPeriod
            ? try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                    windowNumber: sheet.windowNumber, context: nil, characters: ".", charactersIgnoringModifiers: ".",
                    isARepeat: false, keyCode: 47))
            : key(.keyDown, "\u{1b}", code: 53, in: sheet)

        if !sheet.performKeyEquivalent(with: event) { sheet.sendEvent(event) }
        hold.release()

        await until("the unarchive ends") { studio.archiveRun == nil }
        #expect(studio.isArchived, "the key did not stop the unarchive")
        #expect(try clipNames(studio).filter { $0.hasSuffix(".flac") }.count == 1)
        await model.close()
    }

    /// C20: an archive stopped after one of two files leaves a partial state, and the menu gives
    /// Unarchive Session, which completes it.
    @Test func aStoppedArchiveIsCompletedByTheNextUnarchive() async throws {
        let (model, studio, window) = try await window(archived: false, second: true)
        let hold = ArchiveHold()
        studio.environment.archiveBlock = { hold.step() }
        model.toggleArchive()
        try await confirm(in: window)
        await until("the archive holds") { hold.isHeld }
        model.cancelPackageJob()
        hold.release()
        await until("the archive ends") { studio.archiveRun == nil }
        #expect(studio.isArchived && model.archiveMenuTitle == .menuFileUnarchive)
        #expect(try clipNames(studio).filter { $0.hasSuffix(".flac") }.count == 1)

        model.toggleArchive()

        await until("the unarchive ends") { !studio.isArchived && studio.archiveRun == nil }
        #expect(try clipNames(studio) == ["f1.wav", "f2.wav"])
        #expect(try Session(contentsOf: studio.url).archive == nil)
        await model.close()
    }

    /// C20 and C12: the result banner gives the freed bytes less the FLAC bytes, and with a net
    /// over 0 it ends with the APFS snapshot sentence.
    @Test func theResultBannerGivesTheNetBytesAndTheSnapshotSentence() async throws {
        let (model, studio, window) = try await window(archived: false)
        let wav = try fileSizes(of: studio.url.appending(path: "Clips/f1.wav"), name: "f1.wav")

        model.toggleArchive()
        try await confirm(in: window)

        await until("the archive ends") { studio.isArchived && studio.archiveRun == nil }
        let flac = try fileSizes(of: studio.url.appending(path: "Clips/f1.flac"), name: "f1.flac")
        let banner = reportBanner("archiveSaved", model, studio)
        guard case .archiveSaved(let net)? = banner else {
            Issue.record("no result banner: \(String(describing: banner))")
            return
        }
        #expect(net == wav.freed - flac.bytes && net > 0, "net \(net), WAV \(wav), FLAC \(flac)")
        #expect(banner?.text.hasSuffix(" " + L10n.bannerArchiveSnapshot.text) == true, "\(banner?.text ?? "")")
        await model.close()
    }

    /// C12: an archive of a WAV that is an APFS clone frees no bytes, so the result banner gives the
    /// no-space text.
    @Test func anArchiveOfAClonedWAVShowsTheNoSpaceText() async throws {
        let package = try await timelinePackage(in: folder.url, tracks: 1, seconds: 1, audio: true)
        let wav = package.appending(path: "Clips/f1.wav")
        let outside = folder.url.appending(path: "outside.wav")
        try FileManager.default.moveItem(at: wav, to: outside)
        try #require(clonefile(outside.path, wav.path, 0) == 0, "no APFS clone: errno \(errno)")
        let (model, studio, window, _) = try await openLanes(app, package)

        model.toggleArchive()
        try await confirm(in: window)

        await until("the archive ends") { studio.isArchived && studio.archiveRun == nil }
        let banner = reportBanner("archiveSaved", model, studio)
        guard case .archiveSaved(let net)? = banner else {
            Issue.record("no result banner: \(String(describing: banner))")
            return
        }
        #expect(net <= 0, "net \(net)")
        #expect(banner?.text == L10n.bannerArchiveNoSpace.text, "\(banner?.text ?? "")")
        await model.close()
    }

    /// C10: an unarchive that keeps a damaged FLAC names it in the error banner of the job.
    @Test func anUnarchiveNamesTheDamagedFileInABanner() async throws {
        let (model, studio, _) = try await window(archived: true, second: true)
        let flac = studio.url.appending(path: "Clips/f2.flac")
        let data = try Data(contentsOf: flac)
        try data.prefix(data.count / 2).write(to: flac)

        model.toggleArchive()

        await until("the unarchive ends") { !studio.isArchived && studio.archiveRun == nil }
        let banner = reportBanner("archiveDamaged", model, studio)
        guard case .archiveDamaged(let paths)? = banner else {
            Issue.record("no damaged banner: \(String(describing: banner))")
            return
        }
        #expect(paths.count == 1 && paths.first?.hasPrefix("f2.") == true, "\(paths)")
        #expect(try clipNames(studio) == ["f1.wav", "f2.flac"])
        await model.close()
    }

    /// C16: Archive Session... on a window of the Favorites store of the app shows the store alert
    /// before any sheet, and no file changes.
    @Test func archiveOnTheFavoritesStoreShowsTheStoreAlert() async throws {
        let package = try await timelinePackage(in: folder.url, tracks: 1, seconds: 1, audio: true)
        let app = AppDelegate(recordings: nil, favorites: package)
        let (model, studio, window, _) = try await openLanes(app, package)

        model.toggleArchive()

        await until("the alert or the confirm sheet shows") { model.alert != nil || window.attachedSheet != nil }
        #expect(model.alert == .error(.archive(.favoritesStore)), "\(String(describing: model.alert))")
        if model.alert == nil { try await press(.alertCancel, in: window) }
        #expect(try clipNames(studio) == ["f1.wav"] && !studio.isArchived)
        model.alert = nil
        await model.close()
    }

    /// C20: the confirm sheet counts only the pool WAVs that the archive converts, so a 16-bit WAV
    /// is not one. Fail value: the sheet counts 2 files.
    @Test func theConfirmSheetCountsOnlyTheWAVsThatConvert() async throws {
        let (model, studio, _) = try await window(archived: false)
        let sixteen = studio.url.appending(path: "Clips/f3.wav")
        do {
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
            buffer.frameLength = 4_800
            let file = try AVAudioFile(
                forWriting: sixteen,
                settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                    AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
                ])
            try file.write(from: buffer)
        }
        try studio.edit(ripple: false) { (session: inout Session) throws(SessionError) in
            try session.addFile(AudioFile(id: "f3", path: "f3.wav", layout: .mono, length: 4_800))
        }
        let wav = try #require(
            try studio.url.appending(path: "Clips/f1.wav").resourceValues(forKeys: [.fileSizeKey]).fileSize)

        let facts = await archiveFacts(of: studio.session, in: studio.url)

        #expect(facts == ArchiveFacts(files: 1, bytes: Int64(wav)), "\(facts)")
        await model.close()
    }

    /// C20: the progress sheet counts the files that the running job converts. After a stop, one of
    /// the two pool files is a FLAC, so the unarchive shows "file 1 of 1". Fail value: the title
    /// counts the pool, "file 1 of 2". The test runner has no string table, so the title of each count
    /// is the bare key: the assert reads the title with the English table.
    @Test func theProgressSheetCountsTheFilesOfTheJob() async throws {
        let (model, studio, window) = try await window(archived: false, second: true)
        let first = ArchiveHold()
        studio.environment.archiveBlock = { first.step() }
        model.toggleArchive()
        try await confirm(in: window)
        await until("the archive holds") { first.isHeld }
        model.cancelPackageJob()
        first.release()
        await until("the archive ends") { studio.archiveRun == nil }
        #expect(try clipNames(studio) == ["f1.flac", "f2.wav"])
        let hold = ArchiveHold()
        studio.environment.archiveBlock = { hold.step() }

        model.toggleArchive()
        await until("the unarchive holds") { hold.isHeld }
        await runLoopPass()

        try await HeaderStateLineTests().withStrings("en") {
            #expect(model.archiveSheetTitle == L10n.sheetUnarchiveFile.format(1, 1), "\(model.archiveSheetTitle)")
        }
        hold.release()
        await until("the unarchive ends") { !studio.isArchived && studio.archiveRun == nil }
        await model.close()
    }
}
