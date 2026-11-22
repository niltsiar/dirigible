import DirigibleAudio
import DirigibleCore
import Foundation

/// The argument rules and the texts of a preset set and of `preset set` (decision 0080). A command and
/// its MCP tool call them, so both give the same text.
extension ExportText {
    /// The preset name that `text` gives, or the refusal of a name that a session cannot store.
    package static func presetName(_ text: String) throws(ToolError) -> PresetName {
        do throws(SessionError) { return try PresetName(text) } catch { throw ToolError(error.message) }
    }

    /// The options of `preset set`. `format` is wav, flac, aac, or mp3. Nil gives the default: 24 bits,
    /// 128 kbit/s, the session rate, and no loudness target.
    package static func presetOptions(
        format: String, bits: Int?, bitrate: Int?, mono: Bool, rate: Int?, loudness: String?,
        spelling o: OptionSpelling
    ) throws(ToolError) -> PresetOptions {
        let kind: ExportFormat
        switch format {
        case "wav", "flac":
            guard bitrate == nil else { throw ToolError("\(o("bitrate")) is only for aac and mp3.") }
            let depth = try bitDepth(bits, spelling: o)
            kind = format == "wav" ? .wav(depth) : .flac(depth)
        case "aac", "mp3":
            guard bits == nil else { throw ToolError("\(o("bits")) is only for wav and flac.") }
            guard let kbits = BitRate(rawValue: bitrate ?? 128) else {
                throw ToolError("\(o("bitrate")) must be 64, 96, 128, 160, 192, or 256.")
            }
            kind = format == "aac" ? .aac(kbits) : .mp3(kbits)
        default:
            throw ToolError("\(o("format")) must be wav, flac, aac, or mp3.")
        }
        let hertz = try exportRate(rate, spelling: o)
        let target = try loudnessTarget(loudness, spelling: o)
        do throws(SessionError) {
            return try PresetOptions(format: kind, layout: mono ? .mono : .stereo, rate: hertz, loudness: target)
        } catch {
            throw ToolError(error.message)
        }
    }

    /// The refusals of `export` with presets, before any read of the package: an option that a preset
    /// sets (`given` names each such option that the caller gave, in the order of the checks), an `out`
    /// with a file extension, and an `out` inside a package.
    package static func checkPresets(out: String, given: [String], spelling o: OptionSpelling) throws(ToolError) {
        if let first = given.first {
            let flag = o == .cli ? "--preset" : "preset"
            throw ToolError("\(flag) sets the options of each file, so it cannot go with \(o(first)).")
        }
        guard !["wav", "m4a", "mp3", "flac"].contains(URL(filePath: out).pathExtension.lowercased()) else {
            throw ToolError(
                "\(o("out")) is the folder and the file name prefix of the presets, so it must not end in .wav, "
                    + ".m4a, .mp3, or .flac.")
        }
        try checkOutsidePackages(URL(filePath: out))
    }

    package static func noPresetMessage(_ name: String) -> String { "The session has no preset \(name)." }

    /// The refusal of a set whose presets give one file name. A preset given twice gives each of its
    /// targets twice, so the list names each path once.
    package static func presetDuplicatesMessage(_ urls: [URL]) -> String {
        var seen: Set<URL> = []
        let unique = urls.filter { seen.insert($0).inserted }
        return "Two presets or more would write one file: \(list(unique)). Give each preset once, or rename a preset."
    }

    /// The refusal of a preset whose format cannot be written at `rate`.
    package static func presetRateMessage(_ preset: PresetRef, rate: Int, spelling o: OptionSpelling) -> String {
        let change = o == .cli ? "`dirigible preset set`" : "preset_set"
        return "preset \"\(preset.text)\" cannot write \(rate) Hz. Set another rate with \(change)."
    }

    /// The stdout line of a file of a preset set: its path, and with a loudness target a tab and the
    /// loudness line of the file.
    package static func presetLine(_ file: ExportedPreset) -> String {
        file.url.path + (file.result.loudness.map { "\t" + loudnessLine($0) } ?? "")
    }

    /// The counts of a stopped preset set for a tool that has no stderr.
    package static func presetStopCounts(_ stop: ExportPresetsStop) -> String {
        func verb(_ number: Int) -> String { number == 1 ? "was" : "were" }
        return "\(count(stop.written.count)) \(verb(stop.written.count)) written; "
            + "\(count(stop.remaining.count)) \(verb(stop.remaining.count)) not written: \(list(stop.remaining))."
    }
}
