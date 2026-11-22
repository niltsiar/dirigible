import AppKit
import DirigibleAudio
import DirigibleCore
import SwiftUI

/// The panels of the preset sheet. Tests give their own.
struct PresetPanels {
    /// The folder panel of Choose Folder... as a sheet of a window: the prefix that the name field starts
    /// with, and the answer, the folder and the prefix as one URL, or nil for Cancel.
    var chooseFolder: @MainActor (NSWindow, String, @escaping @MainActor (URL?) -> Void) -> Void = {
        window, name, done in
        let panel = ExportPanel.presetFolderPanel(name: name)
        panel.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated { done(response == .OK ? panel.url : nil) }
        }
    }
}

extension ExportPanel {
    /// The save panel of a split export (decision 0067) for a preset set: a folder and a prefix, with no
    /// type, so it adds no extension and asks nothing about the prefix file.
    @MainActor static func presetFolderPanel(name: String) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.nameFieldLabel = L10n.panelExportPrefix.text
        panel.prompt = L10n.startFolderChoose.text
        panel.allowedContentTypes = []
        panel.canCreateDirectories = true
        return panel
    }
}

/// The Loudness pop-up of the Export panel and of the preset Edit pane: each target with its value for the
/// chosen channels, -16 stereo or -19 mono for Podcast.
struct LoudnessPicker: View {
    @Bindable var settings: ExportSettings

    var body: some View {
        Picker(L10n.panelExportLoudness.key, selection: $settings.loudness) {
            Text(L10n.panelExportLoudnessOff.key).tag(LoudnessTarget?.none)
            ForEach(LoudnessTarget.allCases, id: \.self) { target in
                Text(verbatim: name(target)).tag(Optional(target))
            }
        }
    }

    private func name(_ target: LoudnessTarget) -> String {
        let key: L10n =
            switch target {
            case .podcast: .panelExportLoudnessPodcast
            case .speech: .panelExportLoudnessSpeech
            case .ebu: .panelExportLoudnessEBU
            case .atsc: .panelExportLoudnessATSC
            }
        return key.format(Int(target.integrated(for: settings.layout).value))
    }
}

/// Save as Preset... of the Export panel (P-Q2): the button shows a name field; Save stores the options of
/// the panel as a session preset through `save`, which gives the text of a refused name, or nil.
struct SaveAsPresetRow: View {
    let settings: ExportSettings
    let save: @MainActor (ExportOptions, String) -> String?
    @State private var name: String?
    @State private var refusal: String?

    var body: some View {
        if let current = name {
            HStack {
                TextField(L10n.exportPresetsName.text, text: Binding(get: { current }, set: { name = $0 }))
                Button(L10n.exportPresetsSave.key) {
                    refusal = save(settings.options, current)
                    if refusal == nil { name = nil }
                }
            }
            if let refusal { Text(verbatim: refusal).foregroundStyle(.secondary) }
        } else {
            Button(L10n.exportPresetsSaveAs.key) { name = "" }
        }
    }
}

/// The save panel of Export: the window, the name, the session rate, the settings of the pop-ups, the note
/// of unheard tracks, the save of Save as Preset, and the answer.
typealias ExportChoice = (
    NSWindow, String, Int, ExportSettings, String?, @escaping @MainActor (ExportOptions, String) -> String?,
    @escaping @MainActor (ExportTarget?) -> Void
) -> Void
