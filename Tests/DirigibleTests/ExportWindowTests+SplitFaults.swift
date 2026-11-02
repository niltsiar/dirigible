import AppKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Code gate 1 of run 2026-10-28-chapter-export-files: where a set result reaches the user.
extension ExportWindowTests {
    /// Item 1: a set whose media is missing keeps its files, its loudness reports, and its done
    /// banner, and the alert names each part file with faults.
    @Test func aSetWithFaultsKeepsTheDoneBannerAndNamesEachFaultyPart() async throws {
        let (model, studio, _) = try await window(audio: false)
        try threeChapters(studio)

        try await runSet(model, studio, setTarget(options: Self.podcast))

        let parts = ["Ep-01-Intro.wav", "Ep-02-Talk.wav", "Ep-03-Outro.wav"]
        #expect(try setFiles() == parts)
        #expect(model.alert == .exportedSet(media: ["f1.wav"], parts: parts))
        let shown = try #require(model.exportSet, "a set with faults has no done banner")
        #expect(shown.files.map(\.lastPathComponent) == parts && shown.loudness.count == 3)
        guard case .exportSetDone(let files, _, _, _)? = ChromeState.reportBanners(model, studio).first else {
            Issue.record("No done banner: \(ChromeState.reportBanners(model, studio))")
            return
        }
        #expect(files.count == 3)
        await model.close()
    }

    /// Item 2: from the OK of the save panel to the end of the set, no second export can start, also while
    /// the replace sheet shows and while the targets are read off the main actor.
    @Test func noSecondExportStartsFromTheOKOfASplitUntilTheSetEnds() async throws {
        let (model, studio, nsWindow) = try await window()
        try threeChapters(studio)
        try await runSet(model, studio, setTarget())
        let target = setTarget()
        app.chooseExport = { _, _, _, _, _, done in
            self.panels.withLock { $0 += 1 }
            done(target)
        }

        await model.export(.session)

        #expect(model.dialogShowing && !model.canExport && !model.isOn(.export), "the OK left Export on")
        await until("the replace sheet shows") { nsWindow.attachedSheet != nil }
        #expect(!model.canExport && !model.isOn(.export), "Export is on while the replace sheet shows")
        let panelsBefore = panelCalls
        await model.export(.session)
        #expect(panelCalls == panelsBefore, "a second save panel opened")
        let sheet = try #require(nsWindow.attachedSheet)
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
}
