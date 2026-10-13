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

    package init(
        out: String, options: ExportOptions, from: Int, to: Int?, tracks: [TrackID], replace: Bool,
        allowMissing: Bool, spelling: OptionSpelling = .tool
    ) {
        (self.out, self.options, self.from, self.to, self.tracks) = (out, options, from, to, tracks)
        (self.replace, self.allowMissing, self.spelling) = (replace, allowMissing, spelling)
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

    /// The media check of the files in the package, and its refusals.
    package func checkFiles(_ session: Session, package: URL, source: ExportSource) throws(ToolError) {
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

    /// The text of a failed job, or nil for a cancel.
    package func message(_ error: ExportError) -> String? {
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
            ExportText.warnings(of: result, session: session, source: source, output: url)
        )
    }

    /// The stdout lines and then the stderr lines, or "OK" when the job prints none.
    func text(of result: ExportResult, session: Session, source: ExportSource) throws(ToolError) -> String {
        let (stdout, stderr) = try lines(of: result, session: session, source: source)
        return stdout.isEmpty && stderr.isEmpty ? "OK" : (stdout + stderr).joined(separator: "\n")
    }

    /// The job of a tool call on the files. The control gets the progress and gives the cancel.
    func run(_ package: URL, path: String, control: CallControl) throws(ToolError) -> String {
        let session: Session
        do throws(SessionFileError) { session = try Session(contentsOf: package) } catch {
            throw ToolError(error.message(package: path))
        }
        let source = try source(in: session)
        try checkFiles(session, package: package, source: source)
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
