import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio
@testable import DirigibleCore

/// File > Revert To (decision 0043, criteria C18 and C19 of run 14). The menu shows `RevertMenu`
/// of the key window. The submenu itself is an on-screen check (`ax.swift dump`).
@Suite(.serialized) @MainActor struct RevertMenuTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)
    let hal = CountingHAL()

    init() throws {
        folder = try TemporaryFolder()
        let source = folder.url.appending(path: "Voice.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 192_000))
        buffer.frameLength = 192_000
        try AVAudioFile(forWriting: source, settings: format.settings).write(from: buffer)
        app.chooseImport = { _, done in done(source) }
    }

    /// The bytes of `session` as a backup named for `seconds` in `package`.
    func plant(_ session: Session, at seconds: Int, in package: URL) throws -> Backup {
        let scratch = folder.url.appending(path: "backup-\(seconds).dirigible")
        try session.write(to: scratch)
        let backup = Backup(saved: Date(timeIntervalSince1970: TimeInterval(seconds)))
        let backups = package.appending(path: "Backups")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: scratch.appending(path: "session.xml"), to: backups.appending(path: backup.fileName))
        return backup
    }

    /// A key window of track `t1` on channel 1 of `duo`, with 3 backups planted before the open:
    /// a session with no track (oldest), with `t1` only, and with `t1` and `t9` (newest).
    func window() async throws -> (SessionWindow, Studio, [Backup]) {
        let package = try await timelinePackage(in: folder.url, tracks: 1, seconds: 2, audio: true, device: "duo")
        var one = Session(sampleRate: 48_000)
        try one.addTrack("t1", name: "T1", layout: .mono)
        var two = one
        try two.addTrack("t9", name: "T9", layout: .mono)
        let planted = [
            try plant(Session(sampleRate: 48_000), at: 1_000_000_000, in: package),
            try plant(one, at: 1_000_000_600, in: package), try plant(two, at: 1_000_001_200, in: package),
        ]
        let (model, studio, _, _) = try await openLanes(app, package)
        studio.environment = hal.environment
        return (model, studio, planted)
    }

    /// C19: the date and time of the backup in the locale and the time zone of the Mac, with
    /// seconds. The texts are the ones that Foundation gives on macOS 15.
    @Test func theTitleIsTheLocalDateAndTime() throws {
        let date = Date(timeIntervalSince1970: 1_791_524_472)
        let utc = try #require(TimeZone(identifier: "UTC"))
        #expect(
            backupTitle(date, locale: Locale(identifier: "en_US"), timeZone: utc) == "Oct 9, 2026 at 5:41:12\u{202F}AM")
        #expect(backupTitle(date, locale: Locale(identifier: "es_ES"), timeZone: utc) == "9 oct 2026, 5:41:12")
    }

    /// Two backups in one second get milliseconds, so no two items have one title.
    @Test func twoBackupsInOneSecondShowMilliseconds() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let en = Locale(identifier: "en_US")
        let dates = [1_791_524_472.25, 1_791_524_472, 1_791_524_400].map { Date(timeIntervalSince1970: $0) }

        let titles = backupTitles(dates.map(Backup.init(saved:)), locale: en, timeZone: utc)

        #expect(titles.count == 3 && Set(titles).count == 3, "\(titles)")
        #expect(titles[0].contains("12.250"), "\(titles)")
        #expect(titles[2] == backupTitle(dates[2], locale: en, timeZone: utc), "a single title has no milliseconds")
    }

    /// C18: newest first; no window gives no backup.
    @Test func theMenuListsTheBackupsNewestFirst() async throws {
        #expect(RevertMenu(app.key).backups.isEmpty, "no window")
        let (model, _, planted) = try await window()

        #expect(RevertMenu(model).backups == planted.reversed())
        await model.close()
    }

    /// C18: the items are on only while the window takes an edit.
    @Test func theItemsAreOffWhileBusy() async throws {
        #expect(!RevertMenu(nil).enabled, "no window")
        let (model, studio, _) = try await window()
        #expect(RevertMenu(model).enabled, "idle")

        model.armed = ["t1"]
        await model.record()
        #expect(studio.transport == .recording(take: 1))
        #expect(!RevertMenu(model).enabled, "recording")
        await model.stop()
        await until("the take ends") { studio.isIdle }
        #expect(RevertMenu(model).enabled, "idle after the take")

        studio.environment.playerOutput = .offline
        let hold = DispatchSemaphore(value: 0)
        let entered = LockedFlag()
        studio.environment.importStep = {
            guard !entered.value else { return }
            entered.value = true
            _ = hold.wait(timeout: .now() + 30)
        }
        model.run(TimelineCommand.importAudio)
        await until("the import holds") { entered.value }
        #expect(!RevertMenu(model).enabled, "importing")
        hold.signal()
        await until("the import ends") { model.importJob == nil }
        await model.close()
    }

    /// A backup whose pool names a missing file: after the revert, the window shows the file
    /// as missing (code gate 2 item 5).
    @Test func aRevertShowsAMissingFileOfTheBackup() async throws {
        let (model, studio, _) = try await window()
        var missing = studio.session
        try missing.addFile(AudioFile(id: "f9", path: "Clips/Gone.wav", layout: .mono, length: 48_000))
        let backup = try plant(missing, at: 1_000_001_800, in: studio.url)

        model.revert(to: backup)
        await until("the revert ends") { studio.session.files["f9"] != nil }

        await until("the missing file shows") { studio.missingMedia["f9"] != nil }
        #expect(studio.missingMedia["f9"] != nil, "the missing file of the backup shows")
        await model.close()
    }

    /// C18: a click reverts the key window as one undo entry, and VoiceOver hears the backup.
    @Test func aClickReverts() async throws {
        let (model, studio, planted) = try await window()
        let before = studio.session
        var heard: [String] = []
        model.chrome?.announce = { text, _ in heard.append(text) }

        model.revert(to: planted[0])
        await until("the revert ends") { studio.session.tracks.isEmpty }

        #expect(heard == [L10n.revertedTo.format(backupTitle(planted[0].saved))])
        #expect(model.alert == nil && model.canUndo)
        model.undo()
        #expect(studio.session == before, "Undo gives the state before the revert")
        await model.close()
    }
}
