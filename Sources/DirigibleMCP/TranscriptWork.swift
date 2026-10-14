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
    /// skipped word. The command prints the first two on stdout and the others on stderr.
    package static func importLines(_ report: (id: TranscriptID, kept: Int, skipped: Int, untimed: Int)) -> [String] {
        func words(_ count: Int) -> String { count == 1 ? "1 word" : "\(count) words" }
        var lines = [report.id.description, "Imported \(words(report.kept))."]
        if report.skipped > 0 {
            lines.append("Skipped \(words(report.skipped)) with no clip under \(report.skipped == 1 ? "it" : "them").")
        }
        if report.untimed > 0 { lines.append("Skipped \(words(report.untimed)) with no time.") }
        return lines
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

    /// The text of `transcript words`: one row for each shown word, "<occurrence>\t<start>\t<end>\t
    /// <track>\t<text>", at most `query.limit` rows, then a line with the count of the rest. With
    /// `json`, `{"more": <count>, "words": [...]}`. An unknown track gives the error text.
    package static func wordsText(_ session: Session, _ query: TranscriptQuery) throws(ToolError) -> String {
        if let track = query.track, session.track(track) == nil {
            throw ToolError(SessionError.unknownTrack(track).message)
        }
        let all = session.words(in: query.range, matching: query.match, on: query.track.map { [$0] })
        let shown = all.prefix(query.limit)
        let more = all.count - shown.count
        if query.json {
            let rows: [[String: Any]] = shown.map {
                [
                    "occurrence": $0.occurrence.description, "start": $0.range.lowerBound.count,
                    "end": $0.range.upperBound.count, "track": $0.track.rawValue, "text": $0.text,
                ]
            }
            return MCPServer.encode(["more": more, "words": rows])
        }
        guard !all.isEmpty else { return "No words." }
        let lines = shown.map {
            "\($0.occurrence)\t\($0.range.lowerBound)\t\($0.range.upperBound)\t\($0.track)\t\($0.text)"
        }
        return (lines + (more > 0 ? ["\(more) more words: give --from and --to, or --match."] : []))
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
