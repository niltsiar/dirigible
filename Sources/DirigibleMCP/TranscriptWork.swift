import DirigibleAudio
import DirigibleCore
import Foundation

/// The shared bodies and texts of `dirigible transcript` and the transcript tools (decision 0055),
/// so the command and the tool give the same text.
package enum TranscriptWork {
    /// The largest `text` of `transcript_import`: 256 KiB of UTF-8, far under the line limit of the
    /// app server (`AgentListener.maximumLine`). A path and stdin have no limit of their own.
    package static let maximumText = 262_144
    package static let textTooLong = "The text is over 256 KiB. Give the path of the file."
    /// The name of a transcript from stdin or `text` with no name.
    package static let defaultName = "transcript"

    /// The transcript in the file at `path`. The error is the line of the command and the tool.
    package static func file(at path: String) throws(ToolError) -> TranscriptFile {
        let data: Data
        do { data = try Data(contentsOf: URL(filePath: path)) } catch {
            throw ToolError("cannot read \(path): \(error.localizedDescription)")
        }
        return try file(data, source: path)
    }

    /// The transcript in `data`; `source` names it in the error: a path, "stdin", or "text".
    package static func file(_ data: Data, source: String) throws(ToolError) -> TranscriptFile {
        do throws(TranscriptFileError) { return try TranscriptFile(data: data) } catch {
            throw ToolError("\(source): \(error.message)")
        }
    }

    /// The lines of an import: the ID and the count of kept words, then a line for each kind of
    /// skipped word. `transcript import` prints the first two on stdout and the others on stderr.
    /// With no ID (no kept word, so the session did not change), the ID line is left out.
    /// With `cues`, each line names cues, because a cut removes a cue with no word times whole.
    /// With `take`, the second line names the take and the placed and skipped counts, and holds
    /// the skipped units that had no clip under them.
    package static func importLines(
        _ report: (id: TranscriptID?, kept: Int, skipped: Int, untimed: Int, repeated: Int, dropped: [String]),
        cues: Bool, take: Int? = nil
    ) -> [String] {
        let noun = cues ? "cue" : "word"
        func units(_ count: Int) -> String { count == 1 ? "1 \(noun)" : "\(count) \(noun)s" }
        let note = cues ? ": a cut removes a whole cue when it has no word times." : "."
        var lines = report.id.map { [$0.description] } ?? []
        if let take {
            let removed = report.skipped > 0 ? " (audio removed by an edit)" : ""
            lines.append(
                "take \(take): \(units(report.kept)) placed, \(report.skipped) skipped\(removed)" + (cues ? note : ""))
        } else {
            lines.append("Imported \(units(report.kept))" + note)
            if report.skipped > 0 {
                lines.append(
                    "Skipped \(units(report.skipped)) with no clip under \(report.skipped == 1 ? "it" : "them").")
            }
        }
        if report.untimed > 0 { lines.append("Skipped \(units(report.untimed)) with no time.") }
        if report.repeated > 0 {
            lines.append("Skipped \(units(report.repeated)) over audio that an earlier clip already gave.")
        }
        for name in report.dropped { lines.append("Dropped the transcript \(name): its file was missing or damaged.") }
        return lines
    }

    /// The lines of `importLines` with no take for stdout and for stderr: the lines up to and with
    /// the `Imported` line, then the others. A report with no ID has no ID line.
    package static func importOutput(_ lines: [String]) -> (stdout: [String], stderr: [String]) {
        let end = (lines.firstIndex { $0.hasPrefix("Imported ") } ?? -1) + 1
        return (Array(lines[..<end]), Array(lines[end...]))
    }

    /// Runs `edit` with the take map of `read`, for a transcript of take `take`. An anchor of that
    /// take that does not read refuses the edit, because its take time is not known.
    package static func inTake(
        _ session: inout Session, take: Int, read: TakeMapRead,
        _ edit: (inout Session, TakeMap) throws(SessionError) -> [String]
    ) throws(TakeImportError) -> [String] {
        if let fault = read.fault(take: take, in: session) { throw .anchor(fault) }
        do throws(SessionError) { return try edit(&session, read.map) } catch { throw .session(error) }
    }

    /// The occurrences of a cut. A token that does not parse gives the error text.
    package static func occurrences(_ tokens: [String]) throws(ToolError) -> [WordOccurrence] {
        var occurrences: [WordOccurrence] = []
        for token in tokens {
            guard let occurrence = WordOccurrence(token) else {
                throw ToolError("\(token) is not a word occurrence: give the first column of transcript words.")
            }
            occurrences.append(occurrence)
        }
        return occurrences
    }

    /// The lines of a cut: the frames of each range that it cut, "<from> <to>".
    package static func cutLines(_ ranges: [Range<Frames>]) -> [String] {
        ranges.map { "\($0.lowerBound) \($0.upperBound)" }
    }

    /// The text of `transcript words`: a line for each transcript that did not load, then one row
    /// for each shown word, "<occurrence>\t<start>\t<end>\t<track>\t<text>", at most `query.limit`
    /// rows, then a line with the count of the rest. With `json`, `{"more": <count>, "words": [...]}`
    /// and, when a transcript did not load, `"notLoaded"` with those lines. An unknown track gives
    /// the error text.
    package static func wordsText(_ session: Session, _ query: TranscriptQuery) throws(ToolError) -> String {
        if let track = query.track, session.track(track) == nil {
            throw ToolError(SessionError.unknownTrack(track).message)
        }
        let all = session.words(in: query.range, matching: query.match, on: query.track.map { [$0] })
        let shown = all.prefix(query.limit)
        let more = all.count - shown.count
        let notLoaded = session.transcriptsNotLoaded.map {
            "Transcript \($0.id) (\($0.name)): its file is missing or damaged, so its words do not show. Import the "
                + "transcript again."
        }
        if query.json {
            let rows: [[String: Any]] = shown.map {
                [
                    "occurrence": $0.occurrence.description, "start": $0.range.lowerBound.count,
                    "end": $0.range.upperBound.count, "track": $0.track.rawValue, "text": $0.text,
                ]
            }
            let object: [String: Any] = ["more": more, "words": rows]
            return MCPServer.encode(notLoaded.isEmpty ? object : object.merging(["notLoaded": notLoaded]) { $1 })
        }
        guard !all.isEmpty else { return (notLoaded + ["No words."]).joined(separator: "\n") }
        let lines = shown.map {
            "\($0.occurrence)\t\($0.range.lowerBound)\t\($0.range.upperBound)\t\($0.track)\t\($0.text)"
        }
        return (notLoaded + lines + (more > 0 ? ["\(more) more words: narrow with from, to, or match."] : []))
            .joined(separator: "\n")
    }
}

/// The filters of `transcript words` and `transcript_words`, checked.
package struct TranscriptQuery: Sendable {
    let range: Range<Frames>?
    let match: String?
    let track: TrackID?
    let limit: Int
    let json: Bool

    /// Nil `from` and `to` is no range. The error text: one of `from` and `to`, `from` past `to`, or
    /// a limit below 1.
    package init(from: Int?, to: Int?, match: String?, track: String?, limit: Int, json: Bool) throws(ToolError) {
        switch (from, to) {
        case (nil, nil): range = nil
        case (let from?, let to?):
            guard let checked = EditRules.frameRange(from: from, to: to) else {
                throw ToolError("from must not be more than to.")
            }
            range = checked
        default: throw ToolError("Give from and to, or neither.")
        }
        guard limit >= 1 else { throw ToolError("The limit must be 1 or more.") }
        (self.match, self.track, self.limit, self.json) = (match, track.map { TrackID($0) }, limit, json)
    }
}

/// Why an import of a transcript of a take fails.
package enum TakeImportError: Error {
    case session(SessionError)
    /// A take anchor does not read, so the take time is not known.
    case anchor(FinalizeError)

    package var message: String {
        switch self {
        case .session(let error): error.message
        case .anchor(let error): TakeMapError.anchor(error).message
        }
    }
}

extension EditFailure where Body == TakeImportError {
    package func message(package: String) -> String {
        switch self {
        case .file(let error): error.message(package: package)
        case .pendingTake: pendingTakeMessage(package)
        case .splitTake: splitTakeMessage(package)
        case .body(let error): error.message
        }
    }
}

/// The work of a `transcript export` command or a `transcript_export` call after its arguments are
/// checked (decision 0061). It is the one owner of the form of `out`, the refusals, and the warning
/// lines, as `ChaptersWork` is for the chapters export. `Session.subtitleFile` owns the file text.
package struct TranscriptExportWork: Sendable {
    /// An absolute path outside each session package.
    let out: String
    let format: SubtitleFormat
    let transcript: Int?
    let replace: Bool
    let spelling: OptionSpelling

    /// Refuses an `out` that does not end in `.srt` or `.vtt`, or that is in a session package.
    package init(out: String, transcript: Int?, replace: Bool, spelling: OptionSpelling = .tool) throws(ToolError) {
        guard let format = SubtitleFormat(pathExtension: URL(filePath: out).pathExtension) else {
            throw ToolError("\(spelling("out")) must end in .srt or .vtt.")
        }
        if let transcript, transcript < 1 { throw ToolError("The transcript must be 1 or more.") }
        try ExportText.checkOutsidePackages(URL(filePath: out))
        (self.out, self.format, self.transcript, self.replace, self.spelling) = (
            out, format, transcript, replace, spelling
        )
    }

    var url: URL { URL(filePath: out) }

    /// The file text, and the warning lines. The error text is the line of the command and of the
    /// tool.
    package func render(_ session: Session) throws(ToolError) -> (text: String, warnings: [String]) {
        do throws(SubtitleError) {
            let (text, left) = try session.subtitleFile(ofTranscript: transcript, as: format)
            let warnings =
                left == 0
                ? []
                : [
                    "Warning: \(left) cue\(left == 1 ? " has" : "s have") no length and \(left == 1 ? "is" : "are") left out."
                ]
            return (text, warnings)
        } catch {
            throw ToolError(message(error))
        }
    }

    private func message(_ error: SubtitleError) -> String {
        switch error {
        case .noTranscript: "The session has no transcript."
        case .severalTranscripts(let numbers):
            "The session has transcripts \(numbers.map(String.init).joined(separator: ", ")). Give "
                + "\(spelling("transcript"))\(spelling == .cli ? " <id>" : "")."
        case .unknownTranscript(let number): "The session has no transcript \(number)."
        case .notLoaded(let number):
            "Transcript \(number) did not load: its file is missing or damaged. Import the transcript again."
        case .noCue: "The transcript has no word on the timeline."
        }
    }

    /// Refuses an item at `out` with no `replace`. An lstat: a dangling link is an item too.
    /// `[.atomic, .withoutOverwriting]` is a fatal error of Foundation, so the check comes before
    /// the write, and a race with another writer is accepted.
    package func checkTarget() throws(ToolError) {
        guard replace || ConfirmedFile(at: url) == nil else { throw ToolError("\(out) exists.") }
    }

    /// The atomic write: a failed write leaves the old file or no file.
    package func write(_ text: String) throws(ToolError) {
        do { try Data(text.utf8).write(to: url, options: .atomic) } catch {
            throw ToolError("cannot write \(out): \(error.localizedDescription)")
        }
    }

    /// The text of a written file: the warning lines, or "OK".
    static func text(of warnings: [String]) -> String { warnings.isEmpty ? "OK" : warnings.joined(separator: "\n") }

    /// The job of a tool call on the files. It reads with no lock, as the command.
    func run(_ package: URL, path: String) throws(ToolError) -> String {
        let session: Session
        do throws(SessionFileError) { session = try Session(contentsOf: package) } catch {
            throw ToolError(error.message(package: path))
        }
        let (text, warnings) = try render(session)
        try checkTarget()
        try write(text)
        return Self.text(of: warnings)
    }
}
