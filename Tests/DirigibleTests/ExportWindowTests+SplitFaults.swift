import AppKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Code gate 1 of run 2026-10-28-chapter-export-files: where a set result reaches the user.
extension ExportWindowTests {
    /// Item 1: a set whose media is missing keeps its files and its loudness reports, and the alert names
    /// each part file with faults. A set with no older file and a fault has no done banner.
    @Test func aSetWithFaultsAndNoOlderFilesHasNoDoneBannerAndNamesEachFaultyPart() async throws {
        let (model, studio, _) = try await window(audio: false)
        try threeChapters(studio)

        try await runSet(model, studio, setTarget(options: Self.podcast))

        let parts = ["Ep-01-Intro.wav", "Ep-02-Talk.wav", "Ep-03-Outro.wav"]
        #expect(try setFiles() == parts)
        #expect(model.alert == .exportedSet(media: ["f1.wav"], parts: parts))
        let shown = try #require(model.exportSet, "a set with faults has no result")
        #expect(shown.files.map(\.lastPathComponent) == parts && shown.loudness.count == 3)
        #expect(shown.files.count == 3)
        #expect(!ChromeState.reportBanners(model, studio).contains { $0.key == "exportSetDone" })
        await model.close()
    }

    /// A set with a fault and an older file of the prefix still shows the older-files warning.
    @Test func aSetWithFaultsAndOlderFilesKeepsTheOlderFilesWarning() async throws {
        let (model, studio, _) = try await window(audio: false)
        try threeChapters(studio)
        try Data("older set".utf8).write(to: file("Ep-02-Old.wav"))

        try await runSet(model, studio, setTarget(options: Self.podcast))

        let done = ChromeState.reportBanners(model, studio).first { $0.key == "exportSetDone" }
        #expect(done?.kind == .warning, "\(String(describing: done))")
        guard case .exportSetDone(_, let old)? = done else {
            Issue.record("No older-files banner: \(String(describing: done))")
            return
        }
        #expect(old == ["Ep-02-Old.wav"], "\(old)")
        await model.close()
    }

    /// Item 2: from the OK of the save panel to the end of the set, no second export can start, also while
    /// the replace sheet shows and while the targets are read off the main actor.
    @Test func noSecondExportStartsFromTheOKOfASplitUntilTheSetEnds() async throws {
        let (model, studio, nsWindow) = try await window()
        try threeChapters(studio)
        try await runSet(model, studio, setTarget())
        let target = setTarget()
        app.chooseExport = { _, _, _, _, _, _, done in
            self.panels.withLock { $0 += 1 }
            done(target)
        }

        await model.export(.session)

        #expect(model.dialogShowing && !model.canExport && !model.isOn(.export), "the OK left Export on")
        let sheet = try await untilReplaceSheet(of: nsWindow)
        #expect(!model.canExport && !model.isOn(.export), "Export is on while the replace sheet shows")
        let panelsBefore = panelCalls
        await model.export(.session)
        #expect(panelCalls == panelsBefore, "a second save panel opened")
        try #require(sheetButtons(sheet).first { $0.title == L10n.alertCancel.text }).performClick(nil)
        await until("the replace sheet goes") { nsWindow.attachedSheet == nil }
        await until("the flow ends") { model.canExport }

        #expect(model.exportStep == nil && studio.exportProgress == nil)
        await model.close()
    }

    /// Item 7: the next single export removes the banners of the earlier set.
    @Test func aSingleExportRemovesTheBannersOfTheEarlierSet() async throws {
        let (model, studio, _) = try await window()
        try threeChapters(studio)
        try await runSet(model, studio, setTarget())
        try #require(model.exportSet != nil)

        let source = try #require(model.source(of: .session, in: studio))
        await model.run(source, target, studio)

        #expect(model.exportSet == nil, "the set banner stays next to the single export")
        await model.close()
    }

    /// The files that the title banners name.
    func titleBanners(_ model: SessionWindow, _ studio: Studio) -> [String] {
        ChromeState.reportBanners(model, studio).compactMap {
            if case .titleMissing(let file) = $0 { file } else { nil }
        }
    }

    /// Item 8: each part with a warning has its own banner that names its file.
    @Test func eachChapterWarningNamesThePartFileThatHasIt() async throws {
        let mp3 = ExportOptions(format: .mp3(.k128), layout: .stereo, rate: .session)
        let (model, studio, _) = try await window()
        try addPoint("  ", at: 0, studio)
        try addPoint("Talk", at: 3, studio)
        try addPoint("  ", at: 5, studio)
        try await runSet(model, studio, setTarget(options: mp3))

        let files = try setFiles()
        try #require(files.count == 3)
        #expect(titleBanners(model, studio) == [files[0], files[2]], "one banner for each part with no title tag")

        for name in files { try FileManager.default.removeItem(at: file(name)) }
        let ids = Array(studio.session.markers.keys)
        try studio.edit(ripple: false) { session throws(SessionError) in
            for id in ids { try session.removeMarker(id) }
        }
        try threeChapters(studio)
        try studio.edit(ripple: false) { session throws(SessionError) in
            try session.setMarker(Marker(id: MarkerID(), name: "Dup", position: 144_010, kind: .chapter))
        }
        try await runSet(model, studio, setTarget(options: mp3))
        await model.close()
    }

    /// Item 4: a split point with no file of its own gets one banner line, also when the MP3 part leaves
    /// the chapter out of its tags.
    @Test func aDroppedSplitPointGetsOneBannerLine() async throws {
        let mp3 = ExportOptions(format: .mp3(.k128), layout: .stereo, rate: .session)
        let (model, studio, _) = try await window()
        try threeChapters(studio)
        let dup = Marker(id: MarkerID(), name: "Dup", position: 144_010, kind: .chapter)
        try studio.edit(ripple: false) { session throws(SessionError) in try session.setMarker(dup) }

        try await runSet(model, studio, setTarget(options: mp3))

        let banners = ChromeState.reportBanners(model, studio)
        #expect(banners.filter { $0 == .exportSetDropped(dup) }.count == 1, "\(banners)")
        #expect(banners.allSatisfy { $0.kind != .warning || $0 == .exportSetDropped(dup) }, "a second line: \(banners)")
        #expect(banners.last?.text == L10n.bannerExportSetDropped.format("Dup"))
        #expect(try setFiles() == ["Ep-01-Intro.mp3", "Ep-02-Talk.mp3", "Ep-03-Outro.mp3"])
        await model.close()
    }

    /// Item 9: the rows of one window use the key as their identity, so a set with two level warnings and
    /// warnings of two parts has one key for each banner, the done banner among them.
    @Test func eachBannerOfASetHasItsOwnKey() throws {
        func report(gain: Double) throws -> LoudnessReport {
            LoudnessReport(
                target: LUFS(value: -16), measured: LUFS(value: -16 - gain), gain: try #require(Gain(dB: gain)),
                output: LUFS(value: -16), truePeak: -1)
        }
        let (first, second) = (file("Ep-01-A.mp3"), file("Ep-02-B.mp3"))
        let warnings = [first, second].compactMap {
            ChapterWarningsShown(
                [Marker(id: MarkerID(), name: "Dup", position: 1, kind: .chapter)], imagesOmitted: true,
                titleMissing: true, file: $0.lastPathComponent, revision: 1)
        }
        let shown = ExportSetShown(
            files: [first, second], count: 2, loudness: [try report(gain: 24), try report(gain: 25)], old: [],
            warnings: warnings, revision: 1)

        let keys = shown.banners.map(\.key)

        #expect(keys.count == 9 && Set(keys).count == 9, "\(keys)")
    }

    /// Item 10: a number of a banner uses the decimal separator of the current locale.
    @Test func theSetLoudnessNumbersUseTheLocale() {
        #expect(L10n.loudnessNumber(-16.04, locale: Locale(identifier: "de_DE")) == "-16,0")
        #expect(L10n.loudnessNumber(-15.96, locale: Locale(identifier: "en_US")) == "-16.0")
    }
}
