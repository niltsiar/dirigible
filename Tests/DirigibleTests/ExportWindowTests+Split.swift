import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Run 2026-10-28-chapter-export-files, C15: the Files pop-up of the Export save panel and the set
/// flow of the window. The save panel is a stub that answers a split target in the test folder.
extension ExportWindowTests {
    func addPoint(_ name: String, at seconds: Double, kind: Marker.Kind = .chapter, _ studio: Studio) throws {
        try studio.edit(ripple: false) { session throws(SessionError) in
            try session.setMarker(
                Marker(id: MarkerID(), name: name, position: Frames(Int(seconds * 48_000)), kind: kind))
        }
    }

    /// Chapters at 0, 3, and 7 s: the files `Ep-01-Intro`, `Ep-02-Talk`, and `Ep-03-Outro`.
    func threeChapters(_ studio: Studio) throws {
        try addPoint("Intro", at: 0, studio)
        try addPoint("Talk", at: 3, studio)
        try addPoint("Outro", at: 7, studio)
    }

    func setTarget(_ kind: SplitKind = .chapters, options: ExportOptions = ExportWindowTests.options) -> ExportTarget {
        ExportTarget(
            url: folder.url.appending(path: "Ep"), options: options, confirmed: nil,
            split: SplitTarget(kind: kind, folder: folder.url, stem: "Ep"))
    }

    func file(_ name: String) -> URL { folder.url.appending(path: name) }

    func setFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.url.path).filter { $0.hasPrefix("Ep-") }.sorted()
    }

    /// The set job and its source: the whole session.
    func runSet(_ model: SessionWindow, _ studio: Studio, _ target: ExportTarget) async throws {
        let source = try #require(model.source(of: .session, in: studio))
        await model.runSet(source, target.options, try #require(target.split), studio)
    }

    /// The buttons of the replace sheet, in the order of the sheet.
    func sheetButtons(_ sheet: NSWindow) -> [NSButton] {
        func buttons(_ view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
        }
        sheet.contentView?.layoutSubtreeIfNeeded()
        return sheet.contentView.map(buttons) ?? []
    }

    @Test func aChaptersSplitWritesTheSetInThePanelFolder() async throws {
        let (model, studio, _) = try await window()
        try threeChapters(studio)

        try await runSet(model, studio, setTarget())

        #expect(try setFiles() == ["Ep-01-Intro.wav", "Ep-02-Talk.wav", "Ep-03-Outro.wav"])
        #expect(!FileManager.default.fileExists(atPath: file("Ep.wav").path), "the stem file stays unwritten")
        #expect(model.alert == nil)
        let written = try setFiles()
        #expect(model.exportSet?.files.map(\.lastPathComponent) == written)
        #expect(try temporaryFiles() == [])
        await model.close()
    }

    /// Chapters at 2, 4, and 6 s and a plain marker at 3 s from session start 0: with part 00, the
    /// chapters give 4 files and the markers give 5. The count is not the count of the points (3).
    @Test func eachSplitItemShowsItsFileCount() async throws {
        var plan: ExportSplitPlan?
        app.chooseExport = { _, _, _, given, _, done in
            plan = given.plan
            done(nil)
        }
        let (model, studio, _) = try await window()
        for second in [2.0, 4, 6] { try addPoint("C", at: second, studio) }
        try addPoint("M", at: 3, kind: .marker, studio)

        await model.export(.session)

        let shown = try #require(plan, "the panel got no plan")
        #expect(shown.count(.chapters) == 4 && shown.count(.markers) == 5)
        #expect(shown.title(.chapters) == L10n.panelExportFilesChapters.format(4))
        #expect(shown.title(.markers) == L10n.panelExportFilesMarkers.format(5))
        await model.close()
    }

    /// A plan holds the parts that the panel computed once. It has no session, so a tick of the line
    /// and a read of a count cannot build the parts again.
    @Test func thePlanAnswersFromThePartsThatItHoldsAndHasNoSession() async throws {
        let (model, studio, _) = try await window()
        let none = studio.session.exportParts(
            in: try #require(model.source(of: .session, in: studio)).range, by: .chapters, introTitle: "")
        try threeChapters(studio)
        let source = try #require(model.source(of: .session, in: studio))
        let held = studio.session.exportParts(in: source.range, by: .chapters, introTitle: "")
        let plan = ExportSplitPlan(source: source, chapters: held, markers: none)

        #expect(plan.count(.chapters) == 3 && plan.count(.markers) == 0)
        #expect(plan.title(.chapters) == L10n.panelExportFilesChapters.format(3))
        #expect(plan.help(.markers) == .panelExportFilesNoMarkersSession && plan.help(.chapters) == nil)
        #expect(
            plan.line(.chapters, options: Self.options, stem: "Ep", pathExtension: "wav")
                == SplitLine(count: 3, first: "Ep-01-Intro.wav", stemFile: "Ep.wav"))
        #expect(plan.line(.markers, options: Self.options, stem: "Ep", pathExtension: "wav") == nil)
        await model.close()
    }

    @Test func aSplitItemIsOffWithNoPointOfItsKind() async throws {
        var plans: [ExportSplitPlan] = []
        app.chooseExport = { _, _, _, given, _, done in
            plans.append(contentsOf: given.plan.map { [$0] } ?? [])
            done(nil)
        }
        let (model, studio, _) = try await window()
        await model.export(.session)
        try addPoint("M", at: 5, kind: .marker, studio)
        await model.export(.session)
        model.timeline.marks = Marks(inPoint: 48_000, outPoint: 96_000, tracks: ["t1"])
        await model.export(.selection)

        try #require(plans.count == 3)
        #expect(plans[0].help(.chapters) == .panelExportFilesNoChaptersSession)
        #expect(plans[0].help(.markers) == .panelExportFilesNoMarkersSession)
        #expect(plans[1].help(.chapters) == .panelExportFilesNoChaptersSession, "a plain marker is no chapter")
        #expect(plans[1].help(.markers) == nil, "the item is on")
        #expect(plans[2].help(.chapters) == .panelExportFilesNoChaptersSelection, "the selection has no point")
        #expect(plans[2].help(.markers) == .panelExportFilesNoMarkersSelection)
        await model.close()
    }

    @Test func aSplitSetsThePrefixLabelAndTheExportButton() throws {
        let settings = ExportSettings(defaults: nil)
        let panel = NSSavePanel()
        let (label, button) = (panel.nameFieldLabel ?? "", panel.prompt ?? "")
        settings.files = .chapters
        panel.nameFieldStringValue = "Episode 12.wav"

        ExportPanel.follow(settings, panel, nameLabel: label, button: button)
        #expect(panel.nameFieldStringValue == "Episode 12", "the prefix field keeps a stale extension")

        #expect(panel.nameFieldLabel == L10n.panelExportPrefix.text && panel.prompt == L10n.alertExportConfirm.text)
        #expect(panel.allowedContentTypes.isEmpty, "a typed panel asks about the stem file")
        settings.files = .one
        ExportPanel.follow(settings, panel, nameLabel: label, button: button)
        #expect(panel.nameFieldLabel == label && panel.prompt == button)
        #expect(panel.allowedContentTypes == [settings.contentType])
    }

    @Test func theLineNamesTheCountTheFirstFileAndTheStemFile() async throws {
        var plan: ExportSplitPlan?
        app.chooseExport = { _, _, _, given, _, done in
            plan = given.plan
            done(nil)
        }
        let (model, studio, _) = try await window()
        try threeChapters(studio)
        await model.export(.session)

        let line = try #require(plan?.line(.chapters, options: Self.options, stem: "Episode 12", pathExtension: "wav"))

        #expect(line == SplitLine(count: 3, first: "Episode 12-01-Intro.wav", stemFile: "Episode 12.wav"))
        #expect(SplitTarget.stem(of: "Episode 12.wav") == "Episode 12", "an extension of an old format goes")
        #expect(SplitTarget.stem(of: "Ep 12.MP3") == "Ep 12")
        #expect(SplitTarget.stem(of: "Ep 12.5") == "Ep 12.5", "a dot in the name stays")
        await model.close()
    }

    @Test func theLoudnessNoteShowsWithASplitAndATarget() {
        let settings = ExportSettings(defaults: nil)
        settings.files = .markers
        #expect(settings.loudness != nil && settings.showsLoudnessNote)
        settings.loudness = nil
        #expect(!settings.showsLoudnessNote, "the note shows with Loudness Off")
        settings.loudness = .podcast
        settings.files = .one
        #expect(!settings.showsLoudnessNote, "the note shows with One File")
    }

    @Test func aLargeGainWarningNamesItsFile() throws {
        func report(gain: Double) throws -> LoudnessReport {
            LoudnessReport(
                target: LUFS(value: -16), measured: LUFS(value: -16 - gain), gain: try #require(Gain(dB: gain)),
                output: LUFS(value: -16), truePeak: -1)
        }
        let (first, second) = (file("Ep-01-A.wav"), file("Ep-02-B.wav"))
        let shown = ExportSetShown(
            files: [first, second], count: 2, loudness: [try report(gain: 24), try report(gain: 4)], old: [],
            revision: 1)

        let warnings = shown.banners.filter { $0.kind == .warning }

        #expect(warnings == [.exportReport(try report(gain: 24), file: "Ep-01-A.wav")])
        #expect(shown.banners.count == 2, "the done banner and one warning")
    }

    @Test func anExistingPartFileShowsOneReplaceSheet() async throws {
        let (model, studio, nsWindow) = try await window()
        for second in 0..<7 { try addPoint("P\(second)", at: Double(second), studio) }
        try await runSet(model, studio, setTarget())
        // An export writes the same bytes again (decision 0032), so only other bytes show a replace.
        for name in try setFiles() { try Data("old".utf8).write(to: file(name)) }
        let before = try setFiles().map { try Data(contentsOf: file($0)) }
        try #require(before.count == 7)
        let source = try #require(model.source(of: .session, in: studio))
        let (options, split) = (Self.options, try #require(setTarget().split))
        let job = SetJob { await model.runSet(source, options, split, studio) }
        let sheet = try await untilReplaceSheet(of: nsWindow)
        let names = L10n.nameList(try setFiles())
        #expect(names.shown.count == 5 && names.more == 2)
        // Return is an on-screen check: the sheet is not the key window here.
        let escape = key(.keyDown, "\u{1b}", code: 53, in: sheet)
        if !sheet.performKeyEquivalent(with: escape) { sheet.sendEvent(escape) }
        await until(limit: .seconds(10), "Esc closes the sheet") { nsWindow.attachedSheet == nil }
        await job.ends()

        #expect(try setFiles().map { try Data(contentsOf: file($0)) } == before, "Esc replaced a file")
        #expect(nsWindow.attachedSheet == nil && studio.exportProgress == nil)
        await model.close()
    }

    /// Decision 0067: Cancel is the first button and the default, so Return cancels; Replace is the
    /// destructive button and has no key.
    @Test func theReplaceSheetCancelsOnReturnAndReplaceIsDestructive() async throws {
        let (model, studio, _) = try await window()
        let source = try #require(model.source(of: .session, in: studio))

        let question = replaceQuestion(
            ReplaceParts(
                source: source, options: Self.options, split: try #require(setTarget().split), existing: [:], old: []))

        #expect(question.buttons.map(\.title) == [L10n.alertCancel.text, L10n.alertExportReplaceConfirm.text])
        #expect(question.buttons.map(\.keyEquivalent) == ["\r", ""])
        #expect(question.buttons.map(\.hasDestructiveAction) == [false, true])
        await model.close()
    }

    /// The Esc button is transparent and has no title: the accessibility tree of the sheet holds the
    /// buttons Cancel and Replace only.
    @Test func theReplaceSheetShowsVoiceOverOnlyCancelAndReplace() async throws {
        let (model, studio, nsWindow) = try await window()
        try threeChapters(studio)
        try await runSet(model, studio, setTarget())
        let source = try #require(model.source(of: .session, in: studio))
        let (options, split) = (Self.options, try #require(setTarget().split))
        let job = SetJob { await model.runSet(source, options, split, studio) }
        let sheet = try await untilReplaceSheet(of: nsWindow)

        func buttonTitles(_ element: Any) -> [String] {
            let own = (element as? NSButtonCell)?.title.map { [$0] } ?? []
            let children = (element as? NSAccessibilityProtocol)?.accessibilityChildren() ?? []
            return own + children.flatMap(buttonTitles)
        }

        #expect(sheetButtons(sheet).contains { $0.isTransparent }, "the sheet has the Esc button")
        #expect(
            Set(buttonTitles(sheet.contentView as Any)) == [
                L10n.alertCancel.text, L10n.alertExportReplaceConfirm.text,
            ],
            "VoiceOver reads the Esc button")
        try #require(sheetButtons(sheet).first { $0.title == L10n.alertCancel.text }).performClick(nil)
        await until(limit: .seconds(10), "Cancel closes the sheet") { nsWindow.attachedSheet == nil }
        await job.ends()
        await model.close()
    }

    @Test func theReplaceSheetListsTheOldFilesOfTheStemAndKeepsThem() async throws {
        let (model, studio, nsWindow) = try await window()
        try threeChapters(studio)
        try await runSet(model, studio, setTarget())
        let old = Data("older set".utf8)
        for name in ["Ep-02-Old.wav", "Ep-05-Outro.wav"] { try old.write(to: file(name)) }
        try Data("old".utf8).write(to: file("Ep-01-Intro.wav"))
        let source = try #require(model.source(of: .session, in: studio))
        let targets = exportPartTargets(
            studio.session, range: source.range, by: .chapters, options: Self.options, folder: folder.url, stem: "Ep"
        ).targets

        let split = try #require(setTarget().split)
        let set = try #require(
            await model.replacements(source, Self.options, split, targets: targets))
        #expect(set.old.map(\.lastPathComponent) == ["Ep-02-Old.wav", "Ep-05-Outro.wav"])
        #expect(set.names == ["Ep-01-Intro.wav", "Ep-02-Talk.wav", "Ep-03-Outro.wav"])
        let job = SetJob { await model.runSet(source, Self.options, split, studio) }
        let sheet = try await untilReplaceSheet(of: nsWindow)
        try #require(sheetButtons(sheet).first { $0.title == L10n.alertExportReplaceConfirm.text }).performClick(nil)
        await until(limit: .seconds(10), "Replace closes the sheet") { nsWindow.attachedSheet == nil }
        await job.ends()

        #expect(try Data(contentsOf: file("Ep-01-Intro.wav")) != Data("old".utf8), "Replace did not replace")
        for name in ["Ep-02-Old.wav", "Ep-05-Outro.wav"] { #expect(try Data(contentsOf: file(name)) == old) }
        await model.close()
    }

    @Test func theDoneBannerNamesTheOldFilesOfTheStem() async throws {
        let (model, studio, _) = try await window()
        try threeChapters(studio)
        let old = Data("older set".utf8)
        for name in ["Ep-02-Old.wav", "Ep-05-Outro.wav"] { try old.write(to: file(name)) }

        try await runSet(model, studio, setTarget())

        let banners = ChromeState.reportBanners(model, studio)
        guard case .exportSetDone(let files, _, _, let names)? = banners.first else {
            Issue.record("No done banner: \(banners)")
            return
        }
        #expect(
            names == ["Ep-02-Old.wav", "Ep-05-Outro.wav"] && files.count == 3, "a sheet showed or a name is missing")
        for name in ["Ep-02-Old.wav", "Ep-05-Outro.wav"] { #expect(try Data(contentsOf: file(name)) == old) }
        await model.close()
    }

    @Test func theDoneBannerShowsTheFilesInFinder() async throws {
        let (model, studio, _) = try await window()
        try threeChapters(studio)
        var revealed: [URL] = []
        app.reveal = { revealed = $0 }
        try await runSet(model, studio, setTarget())

        guard case .exportSetDone(let files, _, _, _)? = ChromeState.reportBanners(model, studio).first else {
            Issue.record("No done banner")
            return
        }
        model.showInFinder(files)

        #expect(revealed.map(\.lastPathComponent) == ["Ep-01-Intro.wav", "Ep-02-Talk.wav", "Ep-03-Outro.wav"])
        await model.close()
    }

    @Test func aDeletedPointBeforeTheJobShowsTheNoChapterAlert() async throws {
        let (model, studio, _) = try await window()
        try threeChapters(studio)
        let ids = Array(studio.session.markers.keys)
        try studio.edit(ripple: false) { session throws(SessionError) in
            for id in ids { try session.removeMarker(id) }
        }

        try await runSet(model, studio, setTarget())

        guard case .error(let error)? = model.alert, case .exportParts(.noPoint(.chapters, _)) = error else {
            Issue.record("No alert for the missing chapters: \(String(describing: model.alert))")
            return
        }
        #expect(try setFiles() == [] && model.exportSet == nil)
        await model.close()
    }

    @Test func aSetWithPartTitlesShowsNoTitleBanner() async throws {
        let mp3 = ExportOptions(format: .mp3(.k128), layout: .stereo, rate: .session)
        let (model, studio, _) = try await window()
        try threeChapters(studio)
        try await runSet(model, studio, setTarget(options: mp3))
        #expect(titleBanners(model, studio) == [], "the parts have titles")

        let ids = Array(studio.session.markers.keys)
        try studio.edit(ripple: false) { session throws(SessionError) in
            for id in ids { try session.removeMarker(id) }
        }
        try addPoint("  ", at: 0, studio)
        try addPoint("  ", at: 5, studio)
        try await runSet(model, studio, setTarget(options: mp3))
        #expect(titleBanners(model, studio).count == 2, "a part with no title and an episode with none")
        await model.close()
    }
}
