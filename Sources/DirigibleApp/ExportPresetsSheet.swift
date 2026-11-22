import DirigibleAudio
import DirigibleCore
import SwiftUI

/// The folder and the file name prefix of a preset set, from the folder panel of the sheet.
struct PresetFolder: Hashable {
    let folder: URL
    let prefix: String
}

extension BuiltInPreset {
    /// The display name. The stored ID (`rawValue`) is the CLI token and the file name text.
    var title: L10n {
        switch self {
        case .master: .exportPresetsMaster
        case .podcast: .exportPresetsPodcast
        }
    }
}

/// The name of a preset in the app: the display name of a built-in, or the name of a session preset.
func presetTitle(_ ref: PresetRef) -> String {
    switch ref {
    case .builtIn(let preset): preset.title.text
    case .session(let name): name.text
    }
}

/// One line of the options of a preset: the format, the bit depth or the bit rate, the channels, and the
/// loudness target when it is set. The rate is not named (P-Q4).
func presetSummary(_ options: PresetOptions) -> String {
    let (format, detail): (L10n, String) =
        switch options.format {
        case .wav(let bits): (.panelExportFormatWAV, L10n.exportPresetsSummaryBits.format(bits.rawValue))
        case .flac(let bits): (.panelExportFormatFLAC, L10n.exportPresetsSummaryBits.format(bits.rawValue))
        case .aac(let rate): (.panelExportFormatAAC, L10n.panelExportBitrateValue.format(rate.rawValue))
        case .mp3(let rate): (.panelExportFormatMP3, L10n.panelExportBitrateValue.format(rate.rawValue))
        case .floatCAF: preconditionFailure("PresetOptions refuses .floatCAF")
        }
    let channels: L10n = options.layout == .mono ? .panelExportChannelsMono : .panelExportChannelsStereo
    let loudness = options.loudness.map {
        L10n.exportPresetsSummaryLUFS.format(Int($0.integrated(for: options.layout).value))
    }
    return [format.text, detail, channels.text.lowercased(), loudness].compactMap { $0 }.joined(separator: ", ")
}

/// The values of the Edit pane of a session preset: the name field and the pop-ups of the Export panel.
@Observable @MainActor final class PresetEdit {
    let replacing: PresetName
    var name: String
    let settings: ExportSettings
    /// The text of the last refused save.
    var refusal: String?

    init(_ preset: ExportPreset) {
        replacing = preset.name
        name = preset.name.text
        settings = ExportSettings(defaults: nil)
        let options = preset.options
        switch options.format {
        case .wav(let bits): (settings.format, settings.bits) = (.wav, bits)
        case .flac(let bits): (settings.format, settings.bits) = (.flac, bits)
        case .aac(let rate): (settings.format, settings.bitRate) = (.aac, rate)
        case .mp3(let rate): (settings.format, settings.bitRate) = (.mp3, rate)
        case .floatCAF: preconditionFailure("PresetOptions refuses .floatCAF")
        }
        (settings.layout, settings.rate, settings.loudness) = (options.layout, options.rate, options.loudness)
    }
}

/// The state of the preset sheet (decision 0080): the range, the checked presets, the selected row, the
/// folder and prefix, and the Edit pane.
@Observable @MainActor final class PresetSheet {
    /// The checked presets of all sessions (P-Q5): a token for each `PresetRef`, so a session preset and a
    /// built-in of one key have their own checks. The key never changes its meaning or its type (0024 P11).
    nonisolated static let checkedKey = "export.presets.checked"

    /// The whole session, or the Marks selection when the Marks have one.
    let source: ExportSource
    /// True when `source` is the Marks selection.
    let marks: Bool
    @ObservationIgnored private let defaults: UserDefaults?

    var checked: Set<PresetRef> { didSet { defaults?.set(checked.map(Self.token).sorted(), forKey: Self.checkedKey) } }
    var selection: PresetRef?
    var target: PresetFolder?
    var edit: PresetEdit?

    /// With no stored checks, only the podcast preset is checked (E14: both built-ins take 9.5 times one export).
    init(source: ExportSource, marks: Bool, defaults: UserDefaults?) {
        (self.source, self.marks, self.defaults) = (source, marks, defaults)
        checked =
            defaults?.stringArray(forKey: Self.checkedKey).map { Set($0.compactMap(Self.ref)) }
            ?? [.builtIn(.podcast)]
    }

    private static func token(_ ref: PresetRef) -> String {
        switch ref {
        case .builtIn(let preset): "builtIn:" + preset.rawValue
        case .session(let name): "session:" + name.text
        }
    }

    private static func ref(_ token: String) -> PresetRef? {
        let (kind, text) = (token.prefix { $0 != ":" }, String(token.drop { $0 != ":" }.dropFirst()))
        switch kind {
        case "builtIn": return BuiltInPreset(rawValue: text).map { .builtIn($0) }
        case "session": return (try? PresetName(text)).map { .session($0) }
        default: return nil
        }
    }

    func toggle(_ ref: PresetRef) {
        if checked.remove(ref) == nil { checked.insert(ref) }
    }

    /// The built-in presets, then the session presets.
    func presets(in session: Session) -> [(ref: PresetRef, options: PresetOptions)] { session.allExportPresets }

    /// The checked presets in list order. A check of a removed preset stays stored and counts no file.
    func checkedPresets(in session: Session) -> [(ref: PresetRef, options: PresetOptions)] {
        presets(in: session).filter { checked.contains($0.ref) }
    }

    /// Why Export is off, or nil when it is on.
    func caption(in session: Session) -> L10n? {
        if checkedPresets(in: session).isEmpty { return .exportPresetsCaptionNone }
        return target == nil ? .exportPresetsCaptionFolder : nil
    }

    func canExport(in session: Session) -> Bool { caption(in: session) == nil }

    /// "Writes <first file name> and <n> other files.", or the text of two targets of one name, or nil with
    /// no folder or no checked preset. The names are those of `presetTargets`, the names of the set.
    func nameLine(in session: Session) -> String? {
        let presets = checkedPresets(in: session)
        guard let target, !presets.isEmpty else { return nil }
        let names: [String]
        do throws(ExportPresetsError) {
            names = try presetTargets(presets, folder: target.folder, prefix: target.prefix).map(
                \.url.lastPathComponent)
        } catch {
            return L10n.message(for: .exportPresets(error))
        }
        switch names.count {
        case 1: return L10n.exportPresetsNames.format(names[0])
        case 2: return L10n.exportPresetsNamesOne.format(names[0])
        default: return L10n.exportPresetsNamesMany.format(names[0], names.count - 1)
        }
    }
}

/// File > Export with Presets... (decision 0080): the check list of the presets with +, -, and Edit..., the
/// range, the folder line with Choose Folder..., the name line, and Export. Export is off with a caption
/// that says why. Edit... shows a pane inside this sheet. Cancel takes Esc, and Export takes Return.
struct ExportPresetsSheet: View {
    let model: SessionWindow
    let studio: Studio
    @Bindable var sheet: PresetSheet

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.exportPresetsTitle.key).font(.headline)
            if let edit = sheet.edit {
                PresetEditPane(
                    model: model, edit: edit, settings: edit.settings, sessionRate: studio.session.sampleRate)
            } else {
                list
                Text(verbatim: rangeLine).foregroundStyle(.secondary)
                HStack {
                    Text(verbatim: folderLine).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button(L10n.exportPresetsChooseFolder.key) { model.choosePresetFolder() }
                }
                if let line = sheet.nameLine(in: studio.session) {
                    Text(verbatim: line).foregroundStyle(.secondary)
                }
                HStack {
                    if let caption = sheet.caption(in: studio.session) {
                        Text(caption.key).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L10n.alertCancel.key) { model.cancelPresets() }.keyboardShortcut(.cancelAction)
                    Button(L10n.alertExportConfirm.key) { model.runPresets() }
                        .keyboardShortcut(.defaultAction).disabled(!sheet.canExport(in: studio.session))
                }
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $sheet.selection) {
                ForEach(sheet.presets(in: studio.session), id: \.ref) { preset in
                    row(preset.ref, preset.options).tag(preset.ref)
                }
            }
            .onKeyPress(.space) {
                guard let ref = sheet.selection else { return .ignored }
                sheet.toggle(ref)
                return .handled
            }
            .frame(height: 160)
            HStack(spacing: 0) {
                Button {
                    model.copyPreset()
                } label: {
                    Image(systemName: "plus").accessibilityLabel(Text(L10n.exportPresetsAdd.key))
                }
                .disabled(!model.canCopyPreset).help(Text(L10n.exportPresetsAdd.key))
                Button {
                    model.removePreset()
                } label: {
                    Image(systemName: "minus").accessibilityLabel(Text(L10n.exportPresetsRemove.key))
                }
                .disabled(!model.canRemovePreset).help(Text(L10n.exportPresetsRemove.key))
                Spacer()
                Button(L10n.exportPresetsEdit.key) { model.editPreset() }.disabled(!model.canEditPreset)
            }
            .buttonStyle(.borderless)
            .padding(.top, 4)
        }
    }

    /// One check box row: one VoiceOver element with the name and the summary, whose Space checks it.
    private func row(_ ref: PresetRef, _ options: PresetOptions) -> some View {
        let (title, summary) = (presetTitle(ref), presetSummary(options))
        let on = Binding(
            get: { sheet.checked.contains(ref) },
            set: { if $0 { sheet.checked.insert(ref) } else { sheet.checked.remove(ref) } })
        return Toggle(isOn: on) {
            VStack(alignment: .leading) {
                Text(verbatim: title)
                Text(verbatim: summary).font(.caption).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(title), \(summary)"))
        .accessibilityValue(Text(verbatim: on.wrappedValue ? "1" : "0"))
        .accessibilityAddTraits(.isToggle)
        .accessibilityAction { on.wrappedValue.toggle() }
    }

    private var rangeLine: String {
        guard sheet.marks else { return L10n.exportPresetsRangeWhole.text }
        let rate = studio.session.sampleRate
        return L10n.exportPresetsRangeMarks.format(
            SilenceReview.clock(sheet.source.range.lowerBound, rate: rate),
            SilenceReview.clock(sheet.source.range.upperBound, rate: rate))
    }

    private var folderLine: String {
        guard let target = sheet.target else { return L10n.exportPresetsFolderNone.text }
        return target.folder.appending(path: target.prefix).path(percentEncoded: false)
    }
}

/// The Edit pane inside the preset sheet: the name field and the pop-ups of the Export panel. Save stores
/// the preset as one undo step; a refused name shows its text and keeps the pane.
private struct PresetEditPane: View {
    let model: SessionWindow
    @Bindable var edit: PresetEdit
    @Bindable var settings: ExportSettings
    let sessionRate: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                TextField(L10n.exportPresetsName.text, text: $edit.name)
                Picker(L10n.panelExportFormat.key, selection: $settings.format) {
                    Text(L10n.panelExportFormatWAV.key).tag(ExportSettings.Format.wav)
                    Text(L10n.panelExportFormatAAC.key).tag(ExportSettings.Format.aac)
                    Text(L10n.panelExportFormatMP3.key).tag(ExportSettings.Format.mp3)
                    Text(L10n.panelExportFormatFLAC.key).tag(ExportSettings.Format.flac)
                }
                let lossy = settings.format == .aac || settings.format == .mp3
                if lossy {
                    Picker(L10n.panelExportBitrate.key, selection: $settings.bitRate) {
                        ForEach(BitRate.allCases, id: \.self) { rate in
                            Text(verbatim: L10n.panelExportBitrateValue.format(rate.rawValue)).tag(rate)
                        }
                    }
                }
                ExportFormatPickers(
                    bits: $settings.bits, layout: $settings.layout, rate: $settings.rate,
                    sessionRate: sessionRate, showsBits: !lossy)
                LoudnessPicker(settings: settings)
            }
            if let refusal = edit.refusal {
                Text(verbatim: refusal).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(L10n.alertCancel.key) { model.cancelPresetEdit() }.keyboardShortcut(.cancelAction)
                Button(L10n.exportPresetsSave.key) { edit.refusal = model.savePresetEdit() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
