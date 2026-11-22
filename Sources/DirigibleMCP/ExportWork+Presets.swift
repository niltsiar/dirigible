import DirigibleAudio
import DirigibleCore
import Foundation

/// A preset: the name of its file and its options, as `Session.allExportPresets` lists it.
package typealias PresetEntry = (ref: PresetRef, options: PresetOptions)

/// The steps of `export` with presets (decision 0080), on the files and in the app: one file for each
/// preset, in the folder of `out`, named `<prefix>.<ext>` by `presetTargets`.
extension ExportWork {
    /// The form of a preset set. The options of each file come from its preset, so `options` is not read.
    package init(
        presets: [String], out: String, from: Int, to: Int?, tracks: [TrackID], replace: Bool, allowMissing: Bool,
        spelling: OptionSpelling
    ) {
        self.init(
            out: out, options: ExportOptions(BuiltInPreset.master.options), from: from, to: to, tracks: tracks,
            replace: replace, allowMissing: allowMissing, spelling: spelling, presets: presets)
    }

    /// The prefix of the file names: the last part of `out`, with any dot in it.
    var presetPrefix: String { url.lastPathComponent }

    /// The presets that the names give, in order: a session preset before a built-in of one key
    /// (`Session.exportPreset(named:)`). A name that the session does not know is a usage error.
    package func presetList(in session: Session) throws(ToolError) -> [PresetEntry] {
        try presets.map { name throws(ToolError) in
            guard let preset = session.exportPreset(named: name) else {
                throw ToolError(ExportText.noPresetMessage(name))
            }
            return preset
        }
    }

    /// The confirmation of each item that `replace` takes. Refuses two presets of one file name, and an
    /// item at a target with no `replace`. It reads the targets, so call it off the main actor.
    package func presetConfirmations(_ list: [PresetEntry]) throws(ExportPresetsError) -> [URL: ConfirmedFile] {
        var confirmed: [URL: ConfirmedFile] = [:]
        var existing: [URL] = []
        for target in try presetTargets(list, folder: folder, prefix: presetPrefix) {
            guard let item = ConfirmedFile(at: target.url) else { continue }
            if replace { confirmed[target.url] = item } else { existing.append(target.url) }
        }
        guard existing.isEmpty else { throw .exists(existing) }
        return confirmed
    }

    /// The job of a preset set on the files.
    package func exportPresetSet(
        _ session: Session, source: ExportSource, list: [PresetEntry], replacing: [URL: ConfirmedFile], package: URL,
        progress: (Double) -> Void = { _ in }, isCancelled: () -> Bool
    ) throws(ExportPresetsError) -> [ExportedPreset] {
        try exportPresets(
            session, source: source, presets: list, folder: folder, prefix: presetPrefix, replacing: replacing,
            package: { package }, progress: { progress($0.fraction) }, isCancelled: isCancelled)
    }

    /// The stdout lines and the stderr lines of a set that ended with no error: a line for each file and
    /// the warnings of each file. The files that only the export found bad refuse the set, as for one
    /// file: `SetFaults` names each of them.
    package func presetLines(of files: [ExportedPreset], list: [PresetEntry], session: Session, source: ExportSource)
        throws(SetFaults) -> (stdout: [String], stderr: [String])
    {
        let stdout = files.map(ExportText.presetLine)
        let faulty = allowMissing ? [] : files.filter { !$0.result.faults.isEmpty }
        guard faulty.isEmpty else {
            throw SetFaults(
                stdout: stdout, warnings: [],
                refusals: faulty.map {
                    ExportText.readFaultMessage($0.result.faults, in: session, out: $0.url.path, spelling: spelling)
                })
        }
        var warnings: [String] = []
        for file in files {
            guard let format = list.first(where: { $0.ref == file.preset })?.options.format else { continue }
            for line in ExportText.warnings(
                of: file.result, droppedChapters: file.result.droppedChapters, session: session, source: source,
                output: file.url, format: format, spelling: spelling)
            where !warnings.contains(line) {
                warnings.append(line)
            }
        }
        return (stdout, warnings)
    }

    /// The stdout lines and the stderr lines of a set that stopped or failed: a line for each file on
    /// disk, the error text of a failure, and the stop line.
    package func presetStopLines(_ stop: ExportPresetsStop) -> (stdout: [String], stderr: [String]) {
        let failure = message(stop.error, file: stop.remaining.first?.path)
        return (
            stop.written.map(ExportText.presetLine),
            [failure, ExportText.stopLine(remaining: stop.remaining)].compactMap { $0 }
        )
    }

    /// The tool text of a set that stopped or failed.
    func presetStopText(_ stop: ExportPresetsStop) -> String {
        let (stdout, stderr) = presetStopLines(stop)
        return (stdout + stderr).joined(separator: "\n")
    }

    /// The text of a set that the writer refused before the first write.
    package func presetRefusal(_ error: ExportPresetsError) -> String {
        switch error {
        case .exists(let urls): ExportText.partsExistMessage(urls, spelling: spelling)
        case .duplicateTargets(let urls): ExportText.presetDuplicatesMessage(urls)
        case .rateNotSupported(let preset, let rate):
            ExportText.presetRateMessage(preset, rate: rate, spelling: spelling)
        case .stopped(let stop): presetStopText(stop)
        }
    }

    /// The set of a tool call on the files.
    func runPresets(_ session: Session, source: ExportSource, package: URL, control: CallControl)
        throws(ToolError) -> String
    {
        let list = try presetList(in: session)
        try checkFiles(session, package: package, source: source)
        let replacing: [URL: ConfirmedFile]
        do throws(ExportPresetsError) { replacing = try presetConfirmations(list) } catch {
            throw ToolError(presetRefusal(error))
        }
        let files: [ExportedPreset]
        do throws(ExportPresetsError) {
            files = try exportPresetSet(
                session, source: source, list: list, replacing: replacing, package: package, progress: control.report,
                isCancelled: control.isCancelled)
        } catch {
            throw ToolError(presetRefusal(error))
        }
        do throws(SetFaults) {
            let (stdout, stderr) = try presetLines(of: files, list: list, session: session, source: source)
            return (stdout + stderr).joined(separator: "\n")
        } catch {
            throw ToolError(error.text)
        }
    }
}
