import DirigibleAudio
import DirigibleCore
import Foundation

/// The work of an `export` or `render` call or command after its arguments are checked (decisions
/// 0041 and 0049). It is the one owner of the argument rules, the steps, and the texts of
/// `dirigible export`, `dirigible render`, and the two tools. On the files it runs `exportMix` with
/// no lock; in the app, `liveExport`.
package struct ExportWork: Sendable {
    /// An absolute path outside each session package.
    let out: String
    /// `ExportOptions.render` for `render`.
    let options: ExportOptions
    let from: Int
    let to: Int?
    let tracks: [TrackID]
    let replace: Bool
    let allowMissing: Bool
    /// How the texts name an option.
    let spelling: OptionSpelling
    /// Nil for one file. Else one file for each part of the range (decision 0067): `out` gives the
    /// folder, the prefix, and the format.
    let split: SplitKind?
    /// The names of the presets of a preset set (decision 0080), in order; empty for the other forms.
    /// `out` gives the folder and the prefix, and the work reads no `options`.
    let presets: [String]

    package init(
        out: String, options: ExportOptions, from: Int, to: Int?, tracks: [TrackID], replace: Bool,
        allowMissing: Bool, spelling: OptionSpelling = .tool, split: SplitKind? = nil, presets: [String] = []
    ) {
        (self.out, self.options, self.from, self.to, self.tracks) = (out, options, from, to, tracks)
        (self.replace, self.allowMissing, self.spelling, self.split) = (replace, allowMissing, spelling, split)
        self.presets = presets
    }

    var isRender: Bool { options == .render }
    var noun: String { isRender ? "render" : "export" }
    var url: URL { URL(filePath: out) }

    /// The range and the tracks, with the refusals of a usage error.
    package func source(in session: Session) throws(ToolError) -> ExportSource {
        if let unknown = tracks.first(where: { session.track($0) == nil }) {
            throw ToolError(ExportText.noTrackMessage(unknown))
        }
        let end = to ?? session.end.count
        guard end > from,
            let source = ExportSource(range: Frames(from)..<Frames(end), tracks: tracks.isEmpty ? nil : Set(tracks))
        else { throw ToolError(ExportText.rangeMessage(end: session.end, spelling: spelling)) }
        return source
    }

    /// The media check of the files in the package, and its refusals. A render writes a bad file
    /// as silence, so it reads no media state.
    package func checkFiles(_ session: Session, package: URL, source: ExportSource) throws(ToolError) {
        guard !isRender else { return }
        let faults: [FileID: MediaFault]
        do throws(POSIXError) { faults = try checkMedia(session, package: package, source: source) } catch {
            throw ToolError(mediaCheckMessage(error))
        }
        try check(faults, in: session)
    }

    /// Refuses the faults of the media check before an export with no `allow_missing`. A render
    /// writes a bad file as silence.
    func check(_ faults: [FileID: MediaFault], in session: Session) throws(ToolError) {
        guard faults.isEmpty || allowMissing || isRender else {
            throw ToolError(ExportText.faultMessage(faults, in: session, spelling: spelling))
        }
    }

    /// The job on the files. A cancel stops the job before the move of the file, so a cancelled
    /// job leaves no file.
    package func export(
        _ session: Session, source: ExportSource, package: URL, progress: (Double) -> Void = { _ in },
        isCancelled: () -> Bool
    ) throws(ExportError) -> ExportResult {
        // The item at `out` now is the one that `replace` confirms.
        let confirmed = replace ? ConfirmedFile(at: url) : nil
        return try exportMix(
            session, source: source, options: options, to: url, replacing: confirmed, package: { package },
            progress: progress, isCancelled: isCancelled)
    }

    /// The text of a failed job, or nil for a cancel. A set names the file in hand as `file`.
    package func message(_ error: ExportError, file: String? = nil) -> String? {
        let out = file ?? out
        if case .rateNotSupported(let rate) = error, !isRender {
            return ExportText.rateMessage(out: out, rate: rate, spelling: spelling)
        }
        return ExportText.failureMessage(error, out: out, noun: noun, spelling: spelling)
    }

    /// The stdout lines and the stderr lines of a job. An export with a file that only the export
    /// found bad is refused.
    package func lines(of result: ExportResult, session: Session, source: ExportSource) throws(ToolError) -> (
        stdout: [String], stderr: [String]
    ) {
        if isRender {
            return (
                [], ExportText.faultLines(result.faults, in: session) + ExportText.unheardLines(session, source: source)
            )
        }
        // The check found no fault, or `allow_missing`: a fault of the export itself is a file that
        // went bad after the check. The file is written, so the error says so.
        guard result.faults.isEmpty || allowMissing else {
            throw ToolError(ExportText.readFaultMessage(result.faults, in: session, out: out, spelling: spelling))
        }
        return (
            result.loudness.map { [ExportText.loudnessLine($0)] } ?? [],
            ExportText.warnings(
                of: result, droppedChapters: result.droppedChapters, session: session, source: source, output: url,
                format: options.format, spelling: spelling)
        )
    }

    /// The stdout lines and then the stderr lines, or "OK" when the job prints none.
    func text(of result: ExportResult, session: Session, source: ExportSource) throws(ToolError) -> String {
        let (stdout, stderr) = try lines(of: result, session: session, source: source)
        return stdout.isEmpty && stderr.isEmpty ? "OK" : (stdout + stderr).joined(separator: "\n")
    }

    /// The job of a tool call on the files. The control gets the progress and gives the cancel.
    func run(_ package: URL, path: String, control: CallControl) throws(ToolError) -> String {
        let session = try readForSamples(package, path: path)
        let source = try source(in: session)
        if !presets.isEmpty { return try runPresets(session, source: source, package: package, control: control) }
        try checkFiles(session, package: package, source: source)
        if let kind = split { return try runSet(session, source: source, by: kind, package: package, control: control) }
        let result: ExportResult
        do throws(ExportError) {
            result = try export(
                session, source: source, package: package, progress: control.report, isCancelled: control.isCancelled)
        } catch {
            throw ToolError(message(error) ?? cancelledMessage)
        }
        return try text(of: result, session: session, source: source)
    }
}

/// A set whose files only the export found bad, with no `allow_missing`. Each file is on disk.
package struct SetFaults: Error, Sendable {
    /// A line for each written file.
    package let stdout: [String]
    /// A line for each split point with no file of its own.
    package let warnings: [String]
    /// A refusal for each file with faults.
    package let refusals: [String]

    /// The tool text: the stdout lines, the warnings, and the refusals.
    package var text: String { (stdout + warnings + refusals).joined(separator: "\n") }
}

/// A split export that the checks refuse before the first write.
package struct SplitRefusal: Error, Sendable {
    package let message: String
    /// True when the range has no split point: exit 1. Else files exist at the targets: exit 2.
    package let isNoPoint: Bool
}

extension ExportWork {
    var folder: URL { url.deletingLastPathComponent() }
    var prefix: String { url.deletingPathExtension().lastPathComponent }

    /// The files of the set that the targets of `session` name, and the confirmation of each item
    /// that `replace` takes. Refuses a range with no split point, and an item at a target with no
    /// `replace`. It reads the targets, so call it off the main actor.
    package func splitConfirmations(_ session: Session, source: ExportSource, by kind: SplitKind)
        throws(SplitRefusal) -> [URL: ConfirmedFile]
    {
        let targets = exportPartTargets(
            session, range: source.range, by: kind, options: options, folder: folder, prefix: prefix
        ).targets
        guard !targets.isEmpty else {
            throw SplitRefusal(message: ExportText.noPointMessage(kind, range: source.range), isNoPoint: true)
        }
        var confirmed: [URL: ConfirmedFile] = [:]
        var existing: [URL] = []
        for target in targets {
            guard let item = ConfirmedFile(at: target.url) else { continue }
            if replace { confirmed[target.url] = item } else { existing.append(target.url) }
        }
        guard existing.isEmpty else {
            throw SplitRefusal(message: ExportText.partsExistMessage(existing, spelling: spelling), isNoPoint: false)
        }
        return confirmed
    }

    /// The items of the folder that an earlier set of the prefix wrote and `files` do not. It reads
    /// the folder, so call it off the main actor.
    package func oldFiles(besides files: [ExportedPart]) -> [URL] {
        oldPartFiles(
            in: folder, prefix: prefix, format: options.format, besides: Set(files.map(\.url.lastPathComponent)))
    }

    /// The job of a set on the files.
    package func exportSet(
        _ session: Session, source: ExportSource, by kind: SplitKind, replacing: [URL: ConfirmedFile], package: URL,
        progress: (Double) -> Void = { _ in }, isCancelled: () -> Bool
    ) throws(ExportPartsError) -> ExportPartsResult {
        try exportParts(
            session, source: source, by: kind, options: options, folder: folder, prefix: prefix, replacing: replacing,
            package: { package }, progress: { progress($0.fraction) }, isCancelled: isCancelled)
    }

    /// The stdout lines and the stderr lines of a set that ended with no error: a line for each file,
    /// a line for each split point with no file, the warnings of each file, and the line of the older
    /// files of the prefix. The files that only the export found bad refuse the set, as for one file:
    /// `SetFaults` names each of them.
    package func setLines(of result: ExportPartsResult, session: Session, source: ExportSource, old: [URL])
        throws(SetFaults) -> (stdout: [String], stderr: [String])
    {
        let stdout = result.files.map(ExportText.partLine)
        var warnings = ExportText.droppedPointLines(result.dropped)
        let faulty = allowMissing ? [] : result.files.filter { !$0.result.faults.isEmpty }
        guard faulty.isEmpty else {
            throw SetFaults(
                stdout: stdout, warnings: warnings,
                refusals: faulty.map {
                    ExportText.readFaultMessage($0.result.faults, in: session, out: $0.url.path, spelling: spelling)
                })
        }
        for file in result.files {
            for line in ExportText.warnings(
                of: file.result, droppedChapters: result.droppedChapters(of: file), session: session.forPart(file.part),
                source: source, output: file.url, format: options.format, spelling: spelling)
            where !warnings.contains(line) {
                warnings.append(line)
            }
        }
        return (stdout, warnings + [ExportText.oldFilesLine(old)].compactMap { $0 })
    }

    /// The stdout lines and the stderr lines of a set that stopped or failed: a line for each file
    /// on disk, the error text of a failure, and the stop line.
    package func stopLines(_ stop: ExportPartsStop) -> (stdout: [String], stderr: [String]) {
        let failure = message(stop.error, file: stop.remaining.first?.path)
        return (
            stop.written.map(ExportText.partLine),
            [failure, ExportText.stopLine(remaining: stop.remaining)].compactMap { $0 }
        )
    }

    /// The tool text of a set that stopped or failed.
    package func stopText(_ stop: ExportPartsStop) -> String {
        let (stdout, stderr) = stopLines(stop)
        return (stdout + stderr).joined(separator: "\n")
    }

    /// The set of a tool call on the files.
    func runSet(_ session: Session, source: ExportSource, by kind: SplitKind, package: URL, control: CallControl)
        throws(ToolError) -> String
    {
        let replacing: [URL: ConfirmedFile]
        do throws(SplitRefusal) { replacing = try splitConfirmations(session, source: source, by: kind) } catch {
            throw ToolError(error.message)
        }
        let result: ExportPartsResult
        do throws(ExportPartsError) {
            result = try exportSet(
                session, source: source, by: kind, replacing: replacing, package: package, progress: control.report,
                isCancelled: control.isCancelled)
        } catch {
            guard case .stopped(let stop) = error else { throw ToolError(setRefusal(error)) }
            throw ToolError(stopText(stop))
        }
        do throws(SetFaults) {
            let (stdout, stderr) = try setLines(
                of: result, session: session, source: source, old: oldFiles(besides: result.files))
            return (stdout + stderr).joined(separator: "\n")
        } catch {
            throw ToolError(error.text)
        }
    }

    /// The text of a set that the writer refused before the first write.
    package func setRefusal(_ error: ExportPartsError) -> String {
        switch error {
        case .exists(let urls): ExportText.partsExistMessage(urls, spelling: spelling)
        case .noPoint(let kind, let range): ExportText.noPointMessage(kind, range: range)
        case .stopped(let stop): stopText(stop)
        }
    }
}
