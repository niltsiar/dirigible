import Foundation

/// The refusal of a transcript file.
public enum TranscriptFileError: Error, Hashable, Sendable {
    /// The data is neither WebVTT nor JSON of the Whisper shape.
    case unreadable
    /// No unit with a usable time and a text is left.
    case noTimedWord
}

/// A transcript file in seconds, parsed at the boundary (decision 0055): Whisper JSON
/// (`segments[].words[]`, a segment with no words as one unit, or a top-level `words` array) or
/// WebVTT (one unit per cue). Foundation only.
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
    /// True when no unit has word times: WebVTT cues, or Whisper segments with no words. A cut then
    /// removes whole cues.
    public let cues: Bool

    /// `WEBVTT` after an optional byte order mark is WebVTT, else Whisper JSON.
    public init(data: Data) throws(TranscriptFileError) {
        guard let text = String(data: data, encoding: .utf8) else { throw .unreadable }
        let body = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        let (raw, cues) = body.hasPrefix("WEBVTT") ? (Self.cues(body), true) : try Self.whisper(data)
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

    /// The units, and true when no unit is a word.
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
        return (units, !segments.contains { !($0.words ?? []).isEmpty })
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

    /// `hh:mm:ss.ttt` or `mm:ss.ttt`, digits only: `Double` alone also reads a hex float.
    private static func seconds(_ text: String) -> Double? {
        guard let match = text.trimmingCharacters(in: .whitespaces).wholeMatch(of: /(?:(\d+):)?(\d+):(\d+(?:\.\d+)?)/),
            let hours = Double(match.1 ?? "0"), let minutes = Double(match.2), let seconds = Double(match.3)
        else { return nil }
        return hours * 3_600 + minutes * 60 + seconds
    }
}
