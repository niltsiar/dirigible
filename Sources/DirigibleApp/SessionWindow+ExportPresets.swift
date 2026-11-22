import AppKit
import DirigibleAudio
import DirigibleCore
import Foundation

extension SessionWindow {
    /// File > Export with Presets... (decision 0080): the media check of the whole session, the superset of
    /// each range of the sheet, then the question when a file has a fault, then the preset sheet.
    func exportWithPresets() async {
        guard let studio = exportStudio, let whole = source(of: .session, in: studio) else { return }
        await checkMedia(of: whole, then: .presets, in: studio)
    }

    /// The preset sheet over the Marks selection when the Marks have one, else over `whole`. `exportStep` is
    /// `.choosing` while it shows, so no other export starts.
    func openPresetSheet(_ whole: ExportSource, _ studio: Studio) {
        let selection = source(of: .selection, in: studio)
        exportStep = .choosing
        presetSheet = PresetSheet(source: selection ?? whole, marks: selection != nil, defaults: app?.defaults)
    }

    func cancelPresets() {
        presetSheet = nil
        if exportStep == .choosing { exportStep = nil }
    }

    /// Choose Folder...: the 0067 save panel of a folder and a prefix, as a sheet of the preset sheet.
    /// Cancel keeps the folder of the sheet.
    func choosePresetFolder() {
        guard let sheet = presetSheet, let window, let app else { return }
        let name = sheet.target?.prefix ?? url.deletingPathExtension().lastPathComponent
        app.presetPanels.chooseFolder(window.attachedSheet ?? window, name) { [weak sheet] url in
            guard let url, let sheet else { return }
            sheet.target = PresetFolder(
                folder: url.deletingLastPathComponent(), prefix: SplitTarget.prefix(of: url.lastPathComponent))
        }
    }

    /// The selected row of the sheet and its options, while the studio is idle.
    private var selectedPreset: (ref: PresetRef, options: PresetOptions)? {
        guard let selection = presetSheet?.selection, let studio = idleStudio else { return nil }
        return studio.session.allExportPresets.first { $0.ref == selection }
    }

    /// The session preset of the selected row: a built-in cannot change.
    private var selectedSessionPreset: ExportPreset? {
        guard case .session(let name)? = selectedPreset?.ref else { return nil }
        return idleStudio?.session.exportPresets.first { $0.name == name }
    }

    var canCopyPreset: Bool { selectedPreset != nil }
    var canRemovePreset: Bool { selectedSessionPreset != nil }
    var canEditPreset: Bool { selectedSessionPreset != nil }

    /// "+": a session preset "<name> copy" with the options of the selected row, or "<name> copy <n>" with the
    /// first free key, the name cut to `PresetName.maximumLength`. One undo step.
    func copyPreset() {
        guard let (ref, options) = selectedPreset, let studio = idleStudio, let sheet = presetSheet else { return }
        let title = presetTitle(ref)
        for number in 1... {
            let text = copyName(title, number)
            guard let name = try? PresetName(text) else { return }
            var trial = studio.session
            do throws(SessionError) {
                try trial.setExportPreset(ExportPreset(name: name, options: options))
            } catch .presetNameTaken {
                continue
            } catch {
                return
            }
            if store(name: text, options: options, replacing: nil) == nil { sheet.selection = .session(name) }
            return
        }
    }

    /// "-": removes the selected session preset. One undo step.
    func removePreset() {
        guard let preset = selectedSessionPreset, let studio = idleStudio else { return }
        do throws(StudioError) {
            try studio.edit(ripple: false) { session throws(SessionError) in
                try session.removeExportPreset(preset.name)
            }
            presetSheet?.selection = nil
        } catch {
            alert = .error(error)
        }
    }

    /// Edit...: the pane of the selected session preset inside the sheet.
    func editPreset() {
        guard let preset = selectedSessionPreset else { return }
        presetSheet?.edit = PresetEdit(preset)
    }

    /// Save of the Edit pane: stores the preset in the place of the one it edits, as one undo step, and
    /// closes the pane. A refused name gives its text and keeps the pane. A rename keeps the check.
    func savePresetEdit() -> String? {
        guard let sheet = presetSheet, let edit = sheet.edit else { return nil }
        if let refusal = store(name: edit.name, options: edit.settings.options, replacing: edit.replacing) {
            return refusal
        }
        sheet.edit = nil
        guard let name = try? PresetName(edit.name) else { return nil }
        if sheet.checked.remove(.session(edit.replacing)) != nil { sheet.checked.insert(.session(name)) }
        sheet.selection = .session(name)
        return nil
    }

    func cancelPresetEdit() { presetSheet?.edit = nil }

    /// Save as Preset... of the Export panel: stores `options` as a new session preset. One undo step. Gives
    /// the text of a refused name, or nil.
    func savePreset(_ options: ExportOptions, name: String) -> String? {
        store(name: name, options: options, replacing: nil)
    }

    /// Export of the sheet (Return): runs the set when Export is on, else does nothing.
    func runPresets() {
        guard let sheet = presetSheet, sheet.edit == nil, let studio = idleStudio, let target = sheet.target,
            sheet.canExport(in: studio.session)
        else { return }
        let presets = sheet.checkedPresets(in: studio.session)
        presetSheet = nil
        exportStep = .starting
        Task { await runPresetSet(sheet.source, presets, target, studio) }
    }

    /// The name of copy `number` of `title`: the title loses scalars from its end, so the name fits.
    private func copyName(_ title: String, _ number: Int) -> String {
        func name(_ base: String) -> String {
            number == 1 ? L10n.exportPresetsCopy.format(base) : L10n.exportPresetsCopyNumber.format(base, number)
        }
        let room = PresetName.maximumLength - name("").unicodeScalars.count
        var base = String(String.UnicodeScalarView(title.unicodeScalars.prefix(room)))
        while base.last?.isWhitespace == true { base.removeLast() }
        return name(base)
    }

    /// Stores a session preset as one undo step. Gives the text of a refusal, or nil.
    private func store(name text: String, options: ExportOptions, replacing: PresetName?) -> String? {
        guard let studio = idleStudio else { return L10n.message(for: StudioError.busy) }
        do throws(StudioError) {
            try studio.edit(ripple: false) { session throws(SessionError) in
                let options = try PresetOptions(
                    format: options.format, layout: options.layout, rate: options.rate, loudness: options.loudness)
                try session.setExportPreset(
                    ExportPreset(name: try PresetName(text), options: options), replacing: replacing)
            }
            return nil
        } catch {
            return L10n.message(for: error)
        }
    }

    private func store(name text: String, options: PresetOptions, replacing: PresetName?) -> String? {
        store(name: text, options: ExportOptions(options), replacing: replacing)
    }
}
