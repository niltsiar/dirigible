import DirigibleAudio
import DirigibleCore
import Foundation

/// The work of a `chapters export` command or a `chapters_export` call after its arguments are
/// checked. It is the one owner of the range rule, the refusals, the warning lines, and the form
/// of `out`, as `ExportWork` is for `export` (decisions 0011 and 0041). On the files it runs
/// `writeChapters`; in the app, `Studio.exportChapters`.
package struct ChaptersWork: Sendable {
    /// An absolute path outside each session package.
    let out: String
    let form: ChaptersForm
    let from: Int
    let to: Int?
    let replace: Bool
    /// How the texts name an option.
    let spelling: OptionSpelling

    /// Refuses an `out` that does not end in `.json` or `.txt`, or that is in a session package.
    package init(out: String, from: Int, to: Int?, replace: Bool, spelling: OptionSpelling = .tool) throws(ToolError) {
        guard let form = ChaptersForm(of: URL(filePath: out)) else {
            throw ToolError("\(spelling("out")) must end in .json or .txt.")
        }
        try ExportText.checkOutsidePackages(URL(filePath: out))
        (self.out, self.form, self.from, self.to, self.replace, self.spelling) = (
            out, form, from, to, replace, spelling
        )
    }

    var url: URL { URL(filePath: out) }

    /// The range of the export, with the warning lines of the written file.
    package struct Source: Sendable {
        package let range: Range<Frames>
        package let warnings: [String]
    }

    /// A refused export. `range` is a usage error. `nothing` is a range with no chapter, or a
    /// session with no audio and no `to`, with the warning lines that the command prints first.
    package enum Refusal: Error {
        case range(String)
        case nothing(String, warnings: [String])

        /// The text of a tool: the message, then the warning lines.
        package var text: String {
            switch self {
            case .range(let message): message
            case .nothing(let message, let warnings): ([message] + warnings).joined(separator: "\n")
            }
        }
    }

    /// The range and the warning lines, or the refusal. A chapter at or after the session end is
    /// past the audio: the file leaves it out unless `to` is after it, and a warning names it.
    package func source(in session: Session) throws(Refusal) -> Source {
        func past(outside range: Range<Frames>?) -> [String] {
            session.chapters(in: session.end..<Frames.limit).filter { range?.contains($0.position) != true }.map {
                "Warning: chapter \"\($0.name)\" at \($0.position) is at or after the session end \(session.end); "
                    + "the file leaves it out."
            }
        }
        guard to != nil || session.end > .zero else {
            throw .nothing(
                "the session has no audio, so it has no range. Give \(spelling("to")).", warnings: past(outside: nil))
        }
        let end = to ?? session.end.count
        // The range rule of `export`, so both commands take the same ranges.
        guard end > from, let range = ExportSource(range: Frames(from)..<Frames(end))?.range else {
            throw .range(ExportText.rangeMessage(end: session.end, spelling: spelling))
        }
        guard !session.chapters(in: range).isEmpty else {
            throw .nothing("no chapter in frames \(from)..<\(end).", warnings: past(outside: range))
        }
        let list = session.chapterList(in: range)
        var warnings = past(outside: range) + ExportText.droppedLines(list.dropped, pastEnd: false)
        if form == .text, let first = list.chapters.first,
            (first.position - range.lowerBound).count >= session.sampleRate
        {
            warnings.append(
                "Warning: no chapter starts at 00:00:00; Apple Podcasts, Spotify, and YouTube want the first chapter "
                    + "there.")
        }
        return Source(range: range, warnings: warnings)
    }

    /// Refuses an item at `out` with no `replace`. An lstat: a dangling link is an item too.
    /// `[.atomic, .withoutOverwriting]` is a fatal error of Foundation, so the check comes before
    /// the write, and a race with another writer is accepted.
    package func checkTarget() throws(ToolError) {
        guard replace || ConfirmedFile(at: url) == nil else { throw ToolError("\(out) exists.") }
    }

    /// The write on the files: the chapter images beside a JSON, then the file.
    package func write(_ session: Session, source: Source, package: URL) throws(ExportError) {
        try writeChapters(session, in: source.range, to: url, form: form, replacingImages: replace, package: package)
    }

    /// The text of a failed write.
    package func message(_ error: ExportError) -> String {
        // `writeChapters` does not cancel.
        ExportText.failureMessage(error, out: out, noun: "chapters file", spelling: spelling) ?? cancelledMessage
    }

    /// The text of a written file: the warning lines, or "OK".
    static func text(of source: Source) -> String {
        source.warnings.isEmpty ? "OK" : source.warnings.joined(separator: "\n")
    }

    /// The job of a tool call on the files. It reads with no lock, as the command.
    func run(_ package: URL, path: String) throws(ToolError) -> String {
        let session: Session
        do throws(SessionFileError) { session = try Session(contentsOf: package) } catch {
            throw ToolError(error.message(package: path))
        }
        let source: Source
        do throws(Refusal) { source = try self.source(in: session) } catch { throw ToolError(error.text) }
        try checkTarget()
        do throws(ExportError) { try write(session, source: source, package: package) } catch {
            throw ToolError(message(error))
        }
        return Self.text(of: source)
    }
}
