import Foundation

/// The refusal of a transcript file.
public enum TranscriptFileError: Error, Hashable, Sendable {
    /// The data is not WebVTT, not JSON of the Whisper shape, and has no SRT timing line.
    case unreadable
    /// No unit with a usable time and a text is left.
    case noTimedWord
}

/// A transcript file in seconds, parsed at the boundary (decision 0055): Whisper JSON
/// (`segments[].words[]`, a segment with no words as one unit, or a top-level `words` array),
/// WebVTT, or SRT (one unit per cue). Foundation only.
public struct TranscriptFile: Hashable, Sendable {
    public struct Unit: Hashable, Sendable {
        public let start: Double
        public let end: Double
        public let text: String
    }

    /// The units with a usable time and a text, in file order.
    public let units: [Unit]
    /// The count of units with no usable time: none (an unaligned WhisperX word), end before start,
    /// negative, or not finite. A unit with no length keeps its text, so a match finds it.
    public let untimed: Int
    /// True when a unit has no word times: WebVTT or SRT cues, or a Whisper segment with no words, as a
    /// WhisperX segment that did not align. A cut removes such a unit whole.
    public let cues: Bool

    /// After an optional byte order mark, `WEBVTT` is WebVTT, and `{` or `[` after white space is
    /// Whisper JSON. Other text is SRT.
    public init(data: Data) throws(TranscriptFileError) {
        guard let text = String(data: data, encoding: .utf8) else { throw .unreadable }
        let body = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        let raw: [(Double?, Double?, String)]
        let cues: Bool
        if body.hasPrefix("WEBVTT") {
            (raw, cues) = (Self.cues(body), true)
        } else if let first = body.first(where: { !$0.isWhitespace }), "{[".contains(first) {
            (raw, cues) = try Self.whisper(data)
        } else {
            (raw, cues) = (try Self.srt(body), true)
        }
        var units: [Unit] = []
        var untimed = 0
        for (start, end, text) in raw {
            let text = Self.cleaned(text)
            guard !text.isEmpty else { continue }
            guard let start, let end, start.isFinite, end.isFinite, start >= 0, end >= start else {
                untimed += 1
                continue
            }
            units.append(Unit(start: start, end: end, text: text))
        }
        guard !units.isEmpty else { throw .noTimedWord }
        self.units = units
        self.untimed = untimed
        self.cues = cues
    }

    /// The text with each run of white space as one space, no other control character, and no space
    /// at the edges, so it is storable in `session.xml`.
    private static func cleaned(_ text: String) -> String {
        let scalars = text.unicodeScalars.filter { $0.properties.isWhitespace || $0.isStorableInSession }
        return String(String.UnicodeScalarView(scalars)).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private struct Whisper: Decodable {
        struct Word: Decodable {
            let word: String
            let start: Double?
            let end: Double?
        }
        struct Segment: Decodable {
            let start: Double?
            let end: Double?
            let text: String?
            let words: [Word]?
        }
        let segments: [Segment]?
        let words: [Word]?
    }

    /// The units, and true when a unit is a segment with no words.
    private static func whisper(_ data: Data) throws(TranscriptFileError) -> ([(Double?, Double?, String)], Bool) {
        guard let file = try? JSONDecoder().decode(Whisper.self, from: data) else { throw .unreadable }
        // The API gives segments with no words and the words at the top level: the words win.
        if let words = file.words, !words.isEmpty { return (words.map { ($0.start, $0.end, $0.word) }, false) }
        let segments = file.segments ?? []
        let units = segments.flatMap { segment in
            guard let words = segment.words, !words.isEmpty else {
                return [(segment.start, segment.end, segment.text ?? "")]
            }
            return words.map { ($0.start, $0.end, $0.word) }
        }
        return (units, segments.contains { ($0.words ?? []).isEmpty })
    }

    /// One unit per cue: the text lines joined, with each `<...>` tag removed. A NOTE, STYLE, or
    /// REGION block and the header block give none. A timing line that does not parse gives a unit
    /// with no time.
    private static func cues(_ text: String) -> [(Double?, Double?, String)] {
        let blocks = text.replacing("\r\n", with: "\n").replacing("\r", with: "\n").components(separatedBy: "\n\n")
        return blocks.dropFirst().compactMap { block in
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true)
            guard let first = lines.first, !["NOTE", "STYLE", "REGION"].contains(where: { first.hasPrefix($0) }),
                let timing = lines.firstIndex(where: { $0.contains("-->") })
            else { return nil }
            let times = lines[timing].components(separatedBy: "-->")
            let end = times[1].split(separator: " ", omittingEmptySubsequences: true).first.map(String.init)
            let words = lines[(timing + 1)...].joined(separator: " ").replacing(/<[^>]*>/, with: "")
                .replacing("&lt;", with: "<").replacing("&gt;", with: ">").replacing("&amp;", with: "&")
            return (seconds(times[0]), end.flatMap(seconds), words)
        }
    }

    /// One unit per cue: a timing line `hh:mm:ss,ttt --> hh:mm:ss,ttt`, then the text lines, to the
    /// next blank line. A line before a timing line (the index) is ignored, and so are the tags of
    /// the text: `<...>` and `{\...}`. A comma reads as a dot. No timing line is no SRT.
    private static func srt(_ text: String) throws(TranscriptFileError) -> [(Double?, Double?, String)] {
        var cues: [(start: Double?, end: Double?, lines: [Substring])] = []
        var open = false
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if line.allSatisfy(\.isWhitespace) {
                open = false
            } else if line.contains("-->") {
                let times = line.components(separatedBy: "-->").map { $0.replacing(",", with: ".") }
                let end = times[1].split(separator: " ", omittingEmptySubsequences: true).first.map(String.init)
                cues.append((seconds(times[0]), end.flatMap(seconds), []))
                open = true
            } else if open {
                cues[cues.count - 1].lines.append(line)
            }
        }
        guard !cues.isEmpty else { throw .unreadable }
        return cues.map { cue in
            (cue.start, cue.end, cue.lines.joined(separator: " ").replacing(/<[^>]*>|\{\\[^}]*\}/, with: ""))
        }
    }

    /// `hh:mm:ss.ttt` or `mm:ss.ttt`, digits only: `Double` alone also reads a hex float.
    private static func seconds(_ text: String) -> Double? {
        guard let match = text.trimmingCharacters(in: .whitespaces).wholeMatch(of: /(?:(\d+):)?(\d+):(\d+(?:\.\d+)?)/),
            let hours = Double(match.1 ?? "0"), let minutes = Double(match.2), let seconds = Double(match.3)
        else { return nil }
        return hours * 3_600 + minutes * 60 + seconds
    }
}
