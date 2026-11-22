import AppKit
import DirigibleCore
import Foundation
import SwiftUI
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The preset sheet of File > Export with Presets... (decision 0080, criteria E16 to E18): "+", "-", Edit...,
/// Save as Preset..., the name line, and the row summaries.
extension ExportWindowTests {
    // MARK: E16

    @Test func plusCopiesTheSelectedPreset() async throws {
        let (model, studio, _, sheet) = try await presetSheet()
        #expect(!model.canCopyPreset, "no selection")
        sheet.selection = Self.podcastRef
        try await english { model.copyPreset() }
        let copy = try preset("Podcast (MP3) copy", BuiltInPreset.podcast.options)
        #expect(studio.session.exportPresets == [copy], "a copy with the options of the built-in")
        #expect(sheet.selection == .session(copy.name))
        try studio.undo()
        #expect(studio.session.exportPresets.isEmpty, "one undo step")
        model.cancelPresets()
        await model.close()
    }

    @Test func twoCopiesGetTheNumberedNames() async throws {
        let (model, studio, _, sheet) = try await presetSheet()
        let long = try preset(String(repeating: "e\u{301}", count: 32), BuiltInPreset.master.options)
        try await english {
            sheet.selection = Self.podcastRef
            model.copyPreset()
            sheet.selection = Self.podcastRef
            model.copyPreset()
            try studio.edit(ripple: false) { session throws(SessionError) in try session.setExportPreset(long) }
            sheet.selection = .session(long.name)
            model.copyPreset()
        }
        #expect(
            studio.session.exportPresets.map(\.name.text) == [
                "Podcast (MP3) copy", "Podcast (MP3) copy 2", long.name.text,
                String(repeating: "e\u{301}", count: 29) + "e copy",
            ], "the last copy is cut to 64 scalars")
        model.cancelPresets()
        await model.close()
    }

    @Test func minusIsOffForABuiltIn() async throws {
        let (model, studio, _, sheet) = try await presetSheet()
        let show = try preset("Show", BuiltInPreset.master.options)
        try studio.edit(ripple: false) { session throws(SessionError) in try session.setExportPreset(show) }
        #expect(!model.canRemovePreset, "no selection")
        sheet.selection = Self.masterRef
        #expect(!model.canRemovePreset)
        model.removePreset()
        sheet.selection = .session(show.name)
        #expect(model.canRemovePreset)
        model.removePreset()
        #expect(studio.session.exportPresets.isEmpty && sheet.selection == nil)
        try studio.undo()
        #expect(studio.session.exportPresets == [show], "one undo step")
        model.cancelPresets()
        await model.close()
    }

    @Test func editShowsAPaneInTheSameSheet() async throws {
        let (model, studio, window, sheet) = try await presetSheet()
        let show = try preset("Show", BuiltInPreset.master.options)
        try studio.edit(ripple: false) { session throws(SessionError) in try session.setExportPreset(show) }
        await until("the preset sheet shows") { window.attachedSheet != nil }
        sheet.selection = .session(show.name)
        model.editPreset()
        let edit = try #require(sheet.edit)
        #expect(edit.name == "Show" && edit.settings.format == .wav && edit.settings.bits == .bits24)
        let presets = try #require(window.attachedSheet)
        func fields(_ view: NSView?) -> [NSTextField] {
            guard let view else { return [] }
            return ((view as? NSTextField).map { [$0] } ?? []) + view.subviews.flatMap(fields)
        }
        await until("the name field of the pane or a second sheet shows") {
            presets.attachedSheet != nil
                || fields(presets.contentView).contains { $0.isEditable && $0.stringValue == "Show" }
        }
        #expect(presets.attachedSheet == nil, "one sheet: the pane is inside it")

        edit.name = "Show MP3"
        edit.settings.format = .mp3
        edit.settings.bitRate = .k96
        edit.settings.layout = .mono
        #expect(model.savePresetEdit() == nil)
        let saved = try preset(
            "Show MP3", try PresetOptions(format: .mp3(.k96), layout: .mono, rate: .session, loudness: nil))
        #expect(studio.session.exportPresets == [saved] && sheet.edit == nil)
        #expect(sheet.selection == .session(saved.name))
        try studio.undo()
        #expect(studio.session.exportPresets == [show], "one undo step")

        sheet.selection = .session(show.name)
        model.editPreset()
        try #require(sheet.edit).name = "podcast"
        #expect(model.savePresetEdit() == L10n.message(for: .session(.presetNameTaken("podcast"))))
        #expect(studio.session.exportPresets == [show] && sheet.edit != nil, "a taken name keeps the pane")
        model.cancelPresetEdit()
        #expect(sheet.edit == nil)
        model.cancelPresets()
        await model.close()
    }

    @Test func editIsOffForABuiltIn() async throws {
        let (model, _, _, sheet) = try await presetSheet()
        #expect(!model.canEditPreset)
        sheet.selection = Self.podcastRef
        #expect(!model.canEditPreset)
        model.editPreset()
        #expect(sheet.edit == nil)
        model.cancelPresets()
        await model.close()
    }

    @Test func saveAsPresetStoresThePanelOptions() async throws {
        let (model, studio, _) = try await window()
        let options = ExportOptions(format: .mp3(.k96), layout: .mono, rate: .hz44100, loudness: .speech)
        #expect(model.savePreset(options, name: "Show") == nil)
        let stored = try preset(
            "Show", try PresetOptions(format: .mp3(.k96), layout: .mono, rate: .hz44100, loudness: .speech))
        #expect(studio.session.exportPresets == [stored])
        try studio.undo()
        #expect(studio.session.exportPresets.isEmpty, "one undo step")

        var save: (@MainActor (ExportOptions, String) -> String?)?
        app.chooseExport = { _, _, _, _, _, savePreset, _ in save = savePreset }
        await model.export(.session)
        let panelSave = try #require(save)
        let refusal = panelSave(options, "Show")
        #expect(refusal == nil, "the panel gets the save of the window")
        #expect(studio.session.exportPresets == [stored])
        await model.close()
    }

    @Test func saveAsPresetWithATakenNameStoresNothing() async throws {
        let (model, studio, _) = try await window()
        let options = ExportOptions(format: .wav(.bits16), layout: .stereo, rate: .session)
        let before = studio.session
        #expect(model.savePreset(options, name: "MASTER") == L10n.message(for: .session(.presetNameTaken("MASTER"))))
        #expect(model.savePreset(options, name: " ") == L10n.message(for: .session(.invalidPresetName(" "))))
        #expect(studio.session == before)
        #expect(L10n.message(for: .session(.presetNameTaken("x"))) == L10n.errorPresetNameTaken.format("x"))
        await model.close()
    }

    /// The save panel can set the window of its accessory wider than the accessory asks. An accessory that
    /// sets the width back loops with the panel while its name field shows, and the app freezes.
    @Test func theExportAccessoryKeepsTheWidthOfThePanel() throws {
        let host = NSHostingView(
            rootView: ExportAccessory(
                settings: ExportSettings(defaults: nil), sessionRate: 48_000, note: nil, savePreset: { _, _ in nil },
                name: { "Show" }, changed: {}))
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        window.contentView = host
        window.layoutIfNeeded()
        let asked = host.fittingSize
        let wide = NSSize(width: asked.width + 10, height: asked.height)

        window.setContentSize(wide)
        window.updateConstraintsIfNeeded()
        window.layoutIfNeeded()

        #expect(window.contentRect(forFrameRect: window.frame).size == wide, "the accessory asked for \(asked)")
    }

    // MARK: E17, E18

    @Test func theNameLineShowsTheFirstNameAndTheCount() async throws {
        let (model, studio, _, sheet) = try await presetSheet()
        let flac = try preset(
            "Archive", try PresetOptions(format: .flac(.bits16), layout: .stereo, rate: .session, loudness: nil))
        try studio.edit(ripple: false) { session throws(SessionError) in try session.setExportPreset(flac) }
        var lines: [String?] = []
        try await english {
            lines.append(sheet.nameLine(in: studio.session))
            sheet.target = PresetFolder(folder: folder.url, prefix: "show")
            for checked in [
                [Self.masterRef], [Self.masterRef, Self.podcastRef],
                [Self.masterRef, Self.podcastRef, .session(flac.name)],
            ] {
                sheet.checked = Set(checked)
                lines.append(sheet.nameLine(in: studio.session))
            }
        }
        #expect(
            lines == [
                nil, "Writes show.wav.", "Writes show.wav and 1 other file.", "Writes show.wav and 2 other files.",
            ])
        model.cancelPresets()
        await model.close()
    }

    @Test func theListHasTwoBuiltInsAndNoBroadcast() async throws {
        let (model, studio, _, sheet) = try await presetSheet()
        #expect(sheet.presets(in: studio.session).map(\.ref) == [Self.masterRef, Self.podcastRef])
        #expect(Set(BuiltInPreset.allCases.map(\.title)).count == BuiltInPreset.allCases.count, "one key each")
        model.cancelPresets()
        await model.close()
    }

    @Test func aRowShowsItsSummary() async throws {
        try await english {
            #expect(presetSummary(BuiltInPreset.podcast.options) == "MP3, 128 kbit/s, mono, -19 LUFS")
            #expect(presetSummary(BuiltInPreset.master.options) == "WAV, 24-bit, stereo")
            #expect(presetTitle(Self.podcastRef) == "Podcast (MP3)" && presetTitle(Self.masterRef) == "Master (WAV)")
        }
    }

    @Test func aSessionPresetSummaryReadsItsOptions() async throws {
        try await english {
            let flac = try PresetOptions(format: .flac(.bits16), layout: .stereo, rate: .hz48000, loudness: .ebu)
            #expect(presetSummary(flac) == "FLAC, 16-bit, stereo, -23 LUFS")
            let aac = try PresetOptions(format: .aac(.k64), layout: .mono, rate: .session, loudness: .podcast)
            #expect(presetSummary(aac) == "AAC (.m4a), 64 kbit/s, mono, -19 LUFS")
            #expect(presetTitle(.session(try PresetName("Show"))) == "Show")
        }
    }

    @Test func twoTargetsOfOneNameShowTheirText() {
        let url = URL(filePath: "/tmp/show.mp3")
        #expect(
            L10n.message(for: .exportPresets(.duplicateTargets([url])))
                == L10n.errorExportPresetsDuplicate.format("show.mp3"))
    }
}
