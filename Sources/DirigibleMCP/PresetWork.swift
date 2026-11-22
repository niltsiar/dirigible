import DirigibleCore

/// The edits of `preset set`, `preset remove`, and their tools (decisions 0011 and 0080): the one owner
/// of the argument rules. Each edit runs on the session of a package under the lock, or on the session
/// of an open window as one undo step.
package enum PresetWork {
    package typealias Edit = @Sendable (inout Session) throws(SessionError) -> Void

    /// Sets the preset `name`. With `rename`, it is the new name of the preset `rename`, which keeps its
    /// place. Else a name that the session stores changes that preset under its own name, with no key
    /// check; any other name adds a preset, and `Session.setExportPreset` refuses a name that has the
    /// key of another preset or of a built-in. The arguments are checked here: a refusal is a usage error.
    package static func set(
        name: String, format: String, bits: Int?, bitrate: Int?, mono: Bool, rate: Int?, loudness: String?,
        rename: String?, spelling: OptionSpelling
    ) throws(ToolError) -> Edit {
        let options = try ExportText.presetOptions(
            format: format, bits: bits, bitrate: bitrate, mono: mono, rate: rate, loudness: loudness,
            spelling: spelling)
        let new = try ExportText.presetName(name)
        let old = try rename.map { text throws(ToolError) in try ExportText.presetName(text) }
        return { session throws(SessionError) in
            let replacing = old ?? (session.exportPresets.contains { $0.name == new } ? new : nil)
            try session.setExportPreset(ExportPreset(name: new, options: options), replacing: replacing)
        }
    }

    /// Removes the preset `name`.
    package static func remove(name: String) throws(ToolError) -> Edit {
        let name = try ExportText.presetName(name)
        return { session throws(SessionError) in try session.removeExportPreset(name) }
    }
}
