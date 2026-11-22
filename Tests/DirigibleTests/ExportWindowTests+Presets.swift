import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// File > Export with Presets... (decision 0080, criteria E12 to E22) on a real session window: the
/// media question, the preset sheet and its buttons, the name line, the set run, and its progress.
extension ExportWindowTests {
    static let podcastRef = PresetRef.builtIn(.podcast)
    static let masterRef = PresetRef.builtIn(.master)

    /// The window after File > Export with Presets... with no media fault: the preset sheet shows.
    func presetSheet(audio: Bool = true) async throws -> (SessionWindow, Studio, NSWindow, PresetSheet) {
        let (model, studio, window) = try await window(audio: audio)
        await model.exportWithPresets()
        return (model, studio, window, try #require(model.presetSheet, "the preset sheet did not open"))
    }

    func preset(_ name: String, _ options: PresetOptions) throws -> ExportPreset {
        ExportPreset(name: try PresetName(name), options: options)
    }

    /// Runs `body` with the English table, so a format key gets its text.
    func english(_ body: () async throws -> Void) async throws {
        try await HeaderStateLineTests().withStrings("en", body)
    }

    // MARK: E22

    @Test func aMediaFaultAsksBeforeThePresetSheet() async throws {
        let (model, _, _) = try await window(audio: false)

        await model.exportWithPresets()

        guard case .asking(_, let faults, let panel) = model.exportStep else {
            Issue.record("No question: \(String(describing: model.exportStep))")
            return
        }
        #expect(faults == ["f1": .missing] && panel == .presets)
        #expect(model.isAskingExportQuestion && model.exportQuestionPaths == ["f1.wav"])
        #expect(model.presetSheet == nil, "no sheet before the answer")
        model.answerExportQuestion(export: true)
        #expect(model.presetSheet != nil && model.exportStep == .choosing, "the Export answer opens the sheet")
        #expect(panelCalls == 0)
        model.cancelPresets()
        await model.close()
    }

    @Test func aCancelOfThePresetQuestionOpensNoSheet() async throws {
        let (model, _, _) = try await window(audio: false)

        await model.exportWithPresets()
        model.answerExportQuestion(export: false)
        #expect(model.presetSheet == nil && model.exportStep == nil)

        await model.export(.session)
        guard case .asking(_, _, let panel) = model.exportStep else {
            Issue.record("No question: \(String(describing: model.exportStep))")
            return
        }
        #expect(panel == .mix)
        model.answerExportQuestion(export: true)
        #expect(panelCalls == 1 && model.presetSheet == nil, "the mix panel opens, not the preset sheet")
        await model.close()
    }

    @Test func aMissingFileOutsideTheSelectionStillAsks() async throws {
        let (model, studio, _) = try await window()
        try studio.edit(ripple: false) { session throws(SessionError) in
            try session.addFile(AudioFile(id: "f2", path: "f2.wav", layout: .mono, length: 48_000))
            try session.addTrack("t2", name: "T2", layout: .mono)
            try session.place(Clip(id: "c2", file: "f2", start: 0, offset: 0, length: 48_000), on: "t2")
        }
        model.timeline.marks = Marks(inPoint: 0, outPoint: 96_000, tracks: ["t1"])
        let selection = try #require(model.source(of: .selection, in: studio))
        #expect(await studio.exportFaults(selection) == [:], "the Marks read no missing file")

        await model.exportWithPresets()

        guard case .asking(_, let faults, .presets) = model.exportStep else {
            Issue.record("No question: \(String(describing: model.exportStep))")
            return
        }
        #expect(faults == ["f2": .missing], "the check reads the whole session")
        model.answerExportQuestion(export: false)
        await model.close()
    }

    // MARK: E15, E14, E12

    @Test func theItemHasNoKey() {
        let tables = TimelineCommand.fileItems + TimelineCommand.viewGroups.flatMap { $0 }
        #expect(!tables.contains { $0.command == .exportPresets }, "no table item has the command")
        #expect(TimelineCommand.keylessFileItems.contains { $0.command == .exportPresets })
        #expect(TimelineCommand.fileItems.first { $0.command == .exportChapters }?.modifiers == [.command, .option])
    }

    @Test func onlyThePodcastPresetIsCheckedFirst() throws {
        let suite = "presets-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sheet = PresetSheet(source: ExportSource(range: 0..<48_000)!, marks: false, defaults: defaults)
        #expect(sheet.checked == [Self.podcastRef])
        #expect(
            PresetSheet(source: ExportSource(range: 0..<1)!, marks: false, defaults: nil).checked == [Self.podcastRef])
    }

    @Test func aSessionPresetAndABuiltInOfOneKeyHaveTheirOwnChecks() async throws {
        let suite = "presets-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // A stored preset "master", as a file of an older build has it.
        let stored = PresetRef.session(try PresetName("master"))
        let source = ExportSource(range: 0..<48_000)!
        let sheet = PresetSheet(source: source, marks: false, defaults: defaults)
        sheet.checked = [stored]
        let next = PresetSheet(source: source, marks: false, defaults: defaults)
        #expect(next.checked == [stored], "the session preset is checked, the built-in is not")
        next.checked = [Self.masterRef, Self.podcastRef]
        #expect(
            PresetSheet(source: source, marks: false, defaults: defaults).checked == [Self.masterRef, Self.podcastRef])
        #expect(defaults.stringArray(forKey: PresetSheet.checkedKey)?.count == 2)
    }

    @Test func exportIsOffWithNoPresetChecked() async throws {
        let (model, studio, _, sheet) = try await presetSheet()
        sheet.target = PresetFolder(folder: folder.url, prefix: "show")
        sheet.checked = []
        #expect(sheet.caption(in: studio.session) == .exportPresetsCaptionNone)
        #expect(!sheet.canExport(in: studio.session))
        model.runPresets()
        #expect(model.presetSheet === sheet && model.exportStep == .choosing, "Export does nothing")
        sheet.checked = [Self.podcastRef]
        #expect(sheet.caption(in: studio.session) == nil && sheet.canExport(in: studio.session))
        model.cancelPresets()
        #expect(model.presetSheet == nil && model.exportStep == nil)
        await model.close()
    }

    @Test func exportIsOffWithNoFolder() async throws {
        let (model, studio, _, sheet) = try await presetSheet()
        #expect(sheet.target == nil && sheet.checked == [Self.podcastRef])
        #expect(sheet.caption(in: studio.session) == .exportPresetsCaptionFolder)
        #expect(!sheet.canExport(in: studio.session))
        model.cancelPresets()
        await model.close()
    }

    @Test func chooseFolderOpensThe0067Panel() async throws {
        let panel = ExportPanel.presetFolderPanel(name: "show")
        #expect(panel.nameFieldLabel == L10n.panelExportPrefix.text && panel.allowedContentTypes.isEmpty)
        #expect(panel.nameFieldStringValue == "show" && panel.canCreateDirectories)

        var calls: [(name: String, done: @MainActor (URL?) -> Void)] = []
        app.presetPanels.chooseFolder = { _, name, done in calls.append((name, done)) }
        let (model, _, _, sheet) = try await presetSheet()
        model.choosePresetFolder()
        try #require(calls.count == 1)
        #expect(calls[0].name == "timeline", "the name of the session")
        calls[0].done(folder.url.appending(path: "Ep 1"))
        let chosen = folder.url.appending(path: "Ep 1")
        #expect(sheet.target?.prefix == "Ep 1" && sheet.target.map { $0.folder.appending(path: $0.prefix) } == chosen)
        model.choosePresetFolder()
        calls[1].done(nil)
        #expect(sheet.target.map { $0.folder.appending(path: $0.prefix) } == chosen, "Cancel keeps the folder")
        model.cancelPresets()
        await model.close()
    }

    @Test func theRangeIsTheSelectionWhenTheMarksHaveOne() async throws {
        let (model, studio, _) = try await window()
        await model.exportWithPresets()
        var sheet = try #require(model.presetSheet)
        #expect(sheet.source == ExportSource(range: 0..<studio.session.end) && !sheet.marks)
        model.cancelPresets()

        model.timeline.marks = Marks(inPoint: 48_000, outPoint: 96_000, tracks: ["t1"])
        await model.exportWithPresets()
        sheet = try #require(model.presetSheet)
        #expect(sheet.source == ExportSource(range: 48_000..<96_000, tracks: ["t1"]) && sheet.marks)
        model.cancelPresets()
        await model.close()
    }

    // MARK: E19

    @Test func returnRunsExportWhenOn() async throws {
        let (model, _, _, sheet) = try await presetSheet()
        sheet.target = PresetFolder(folder: folder.url, prefix: "show")
        sheet.checked = [Self.masterRef]
        model.runPresets()
        #expect(model.presetSheet == nil && model.exportStep == .starting, "the set starts")
        await until("the set ends") { model.exportStep == nil && model.studio?.exportProgress == nil }
        #expect(FileManager.default.fileExists(atPath: folder.url.appending(path: "show.wav").path))
        #expect(model.exportSet?.files.map(\.lastPathComponent) == ["show.wav"] && model.alert == nil)
        await model.close()
    }

    @Test func returnDoesNothingWhenExportIsOff() async throws {
        let (model, _, _, sheet) = try await presetSheet()
        sheet.checked = [Self.masterRef]
        model.runPresets()
        #expect(model.presetSheet === sheet && model.exportStep == .choosing)
        model.cancelPresets()
        await model.close()
    }

    // MARK: E20, E21, the set

    @Test func theFileMenuOrder() {
        #expect(
            TimelineCommand.fileMenuTitles == [
                .menuFileImport, .menuFileImportTranscript, .menuFileShowClips, .menuFileExport,
                .menuFileExportSelection, .menuFileExportStems, .menuFileExportPresets, .menuFileExportChapters,
                .menuFileExportTranscript, .menuFileEpisodeInfo,
            ])
    }

    @Test func theProgressNamesThePresetInHand() async throws {
        let (model, studio, _, sheet) = try await presetSheet()
        let hold = PartHold(folder: folder.url, prefix: ".show.mp3")
        studio.environment.exportChunk = { hold.step() }
        defer { hold.release() }
        sheet.target = PresetFolder(folder: folder.url, prefix: "show")
        sheet.checked = [Self.masterRef, Self.podcastRef]
        model.runPresets()
        await until("the set holds in file 2") { hold.isHeld && studio.exportFile?.number == 2 }
        #expect(studio.exportPresetRefs == [Self.masterRef, Self.podcastRef])
        try await english { #expect(model.sheetTitle == "Exporting Podcast (MP3)") }
        model.cancelExport()
        hold.release()
        await until("the set ends") {
            model.exportStep == nil && studio.exportProgress == nil && model.exportSet != nil
        }
        #expect(model.exportSet?.stopped == true && model.exportSet?.count == 2, "the count banner")
        await model.close()
    }

    @Test func anItemAtATargetAsksBeforeTheSet() async throws {
        let (model, _, window, sheet) = try await presetSheet()
        let old = folder.url.appending(path: "show.wav")
        try Data("old".utf8).write(to: old)
        sheet.target = PresetFolder(folder: folder.url, prefix: "show")
        sheet.checked = [Self.masterRef]
        model.runPresets()
        let alert = try await untilReplaceSheet(of: window)
        try #require(sheetButtons(alert).first { $0.title == L10n.alertCancel.text }).performClick(nil)
        await until("the set ends") { model.exportStep == nil }
        #expect(try Data(contentsOf: old) == Data("old".utf8), "Cancel keeps the old file")

        await model.exportWithPresets()
        let next = try #require(model.presetSheet)
        next.target = PresetFolder(folder: folder.url, prefix: "show")
        next.checked = [Self.masterRef]
        model.runPresets()
        let second = try await untilReplaceSheet(of: window)
        try #require(sheetButtons(second).first { $0.title == L10n.alertExportReplaceConfirm.text }).performClick(nil)
        await until("the set ends") {
            model.exportStep == nil && model.studio?.exportProgress == nil && model.exportSet != nil
        }
        #expect(try Data(contentsOf: old) != Data("old".utf8), "Replace writes the new file")
        await model.close()
    }
}
