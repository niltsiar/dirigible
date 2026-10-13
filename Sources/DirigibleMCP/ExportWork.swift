import DirigibleAudio
import DirigibleCore
import Foundation

/// The work of an `export` or `render` call after its arguments are checked (decision 0049). The
/// steps and texts are those of `dirigible export` and `dirigible render`, from `ExportText`. On
/// the files it runs `exportMix` with no lock, as the commands; in the app, `liveExport`.
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

    var isRender: Bool { options == .render }
    var noun: String { isRender ? "render" : "export" }
    var url: URL { URL(filePath: out) }

    /// The range and the tracks, with the refusals of the command.
    func source(in session: Session) throws(ToolError) -> ExportSource {
        if let unknown = tracks.first(where: { session.track($0) == nil }) {
            throw ToolError(ExportText.noTrackMessage(unknown))
        }
        let end = to ?? session.end.count
        guard end > from,
            let source = ExportSource(range: Frames(from)..<Frames(end), tracks: tracks.isEmpty ? nil : Set(tracks))
        else { throw ToolError(ExportText.rangeMessage(end: session.end, spelling: .tool)) }
        return source
    }

    /// Refuses the faults of the media check before an export with no `allow_missing`. A render
    /// writes a bad file as silence, as `dirigible render`.
    func check(_ faults: [FileID: MediaFault], in session: Session) throws(ToolError) {
        guard faults.isEmpty || allowMissing || isRender else {
            throw ToolError(ExportText.faultMessage(faults, in: session, spelling: .tool))
        }
    }

    /// The text of a failed job. A cancel has the cancel text: the client gets no answer.
    func message(_ error: ExportError) -> String {
        if case .rateNotSupported(let rate) = error, !isRender {
            return ExportText.rateMessage(out: out, rate: rate, spelling: .tool)
        }
        return ExportText.failureMessage(error, out: out, noun: noun, spelling: .tool) ?? cancelledMessage
    }

    /// The stdout lines and then the stderr lines of the command, or "OK" when it prints none. An
    /// export with a file that only the export found bad is refused, as the command refuses it.
    func text(of result: ExportResult, session: Session, source: ExportSource) throws(ToolError) -> String {
        let lines: [String]
        if isRender {
            lines = ExportText.faultLines(result.faults, in: session) + ExportText.unheardLines(session, source: source)
        } else {
            guard result.faults.isEmpty || allowMissing else {
                throw ToolError(ExportText.readFaultMessage(result.faults, in: session, out: out, spelling: .tool))
            }
            lines =
                (result.loudness.map { [ExportText.loudnessLine($0)] } ?? [])
                + ExportText.warnings(of: result, session: session, source: source, output: url)
        }
        return lines.isEmpty ? "OK" : lines.joined(separator: "\n")
    }

    /// The job on the files. The control gets the progress, and its cancel stops the job before
    /// the move of the file, so a cancelled job leaves no file.
    func run(_ package: URL, path: String, control: CallControl) throws(ToolError) -> String {
        let session: Session
        do throws(SessionFileError) { session = try Session(contentsOf: package) } catch {
            throw ToolError(error.message(package: path))
        }
        let source = try source(in: session)
        let faults: [FileID: MediaFault]
        do throws(POSIXError) { faults = try checkMedia(session, package: package, source: source) } catch {
            throw ToolError(mediaCheckMessage(error))
        }
        try check(faults, in: session)
        // The item at `out` now is the one that `replace` confirms.
        let confirmed = replace ? ConfirmedFile(at: url) : nil
        let result: ExportResult
        do throws(ExportError) {
            result = try exportMix(
                session, source: source, options: options, to: url, replacing: confirmed, package: { package },
                progress: control.report, isCancelled: control.isCancelled)
        } catch {
            throw ToolError(message(error))
        }
        return try text(of: result, session: session, source: source)
    }
}
