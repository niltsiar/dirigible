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

extension ChaptersWork {
    /// The work of a `chapters import` command or a `chapters_import` call. It is the one owner of
    /// the rules of the file, `at`, `replace`, and the warning lines, as `ChaptersWork` is for the
    /// export (decisions 0011 and 0041). The file is read and parsed in `init`, in the argument
    /// step, so `apply` does no file I/O and runs in the edit of a package or of the app.
    package struct Import: Sendable {
        let file: ImportedChapters
        let at: Frames
        let replace: Bool

        /// The frame `at`, or the usage error: a frame in `0...Frames.limit`. The check comes before
        /// any `Frames` sum.
        package static func frame(at: Int, spelling: OptionSpelling) throws(ToolError) -> Frames {
            guard (0...Frames.limit.count).contains(at) else {
                throw ToolError("\(spelling("at")) is a frame in 0...2^40.")
            }
            return Frames(at)
        }

        /// The largest chapters file, 1 MiB.
        static let maximumBytes = 1 << 20

        /// Reads and parses the chapters file at `path`. The tool runs it on the listener queue of
        /// the app, so before the read it refuses a file that is not on this Mac, that is not a
        /// regular file (a FIFO can block with no end), or that is larger than `maximumBytes`. The
        /// error text is the line of the command and of the tool.
        package init(path: String, at: Frames, replace: Bool) throws(ToolError) {
            guard sourceIsDownloaded(URL(filePath: path)) else {
                throw ToolError("\(path) is not on this Mac. Download the file first.")
            }
            // With O_NONBLOCK, the open of a FIFO with no writer does not wait.
            let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { throw ToolError("cannot read \(path): \(String(cString: strerror(errno)))") }
            defer { close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
                throw ToolError("\(path) is not a file.")
            }
            guard Int(info.st_size) <= Self.maximumBytes else { throw ToolError("\(path) is larger than 1 MiB.") }
            let data: Data
            do {
                data =
                    try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).read(upToCount: Self.maximumBytes)
                    ?? Data()
            } catch {
                throw ToolError("cannot read \(path): \(error.localizedDescription)")
            }
            do throws(ChaptersFileError) { file = try ImportedChapters(data: data) } catch {
                throw ToolError("\(path): \(error.message)")
            }
            (self.at, self.replace) = (at, replace)
        }

        /// The edit: the IDs of the new markers in file order, and the warning lines.
        package func apply(_ session: inout Session) throws(SessionError) -> (ids: [String], warnings: [String]) {
            let report = try session.importChapters(file, at: at, replacing: replace)
            var warnings = file.droppedURLs.map {
                "Warning: chapter \($0) has a url that is not an http or https link of at most "
                    + "\(Marker.maximumURLBytes) bytes; it is not imported."
            }
            if report.imagesLeft > 0 {
                let count = report.imagesLeft
                warnings.append(
                    "Warning: \(count) chapter\(count == 1 ? " has" : "s have") an img that is not imported: the "
                        + "import copies no image.")
            }
            return (report.markers.map(\.rawValue), warnings)
        }
    }
}
