import Foundation

/// One subtitle cue on the timeline: a transcript unit with its text.
public struct Cue: Hashable, Sendable {
    public let start: Frames
    public let end: Frames
    public let text: String
}

/// Why a transcript gives no cues.
public enum SubtitleError: Error, Hashable, Sendable {
    /// The session has no transcript.
    case noTranscript
    /// More than one transcript, and none was named.
    case severalTranscripts([Int])
    /// No transcript has this number.
    case unknownTranscript(Int)
    /// The file of this transcript did not load.
    case notLoaded(Int)
    /// The transcript has no word on the timeline with a length. `left` units have none.
    case noCue(left: Int)
}

extension Session {
    /// The cues of a transcript in timeline order, and the count of units left out because their
    /// range has no length (decision 0061). `number` nil picks the only transcript. One unit at one
    /// start on two tracks (one file on both) is one cue, with the later end.
    public func cues(ofTranscript number: Int?) throws(SubtitleError) -> (cues: [Cue], left: Int) {
        let ids = transcripts.keys.sorted()
        let id: TranscriptID
        if let number {
            guard let found = ids.first(where: { $0.number == number }) else { throw .unknownTranscript(number) }
            id = found
        } else {
            guard let only = ids.first else { throw .noTranscript }
            guard ids.count == 1 else { throw .severalTranscripts(ids.map(\.number)) }
            id = only
        }
        guard transcripts[id]?.words != nil else { throw .notLoaded(id.number) }
        var units: [(word: WordID, start: Frames, end: Frames, text: String)] = []
        for word in words() where word.occurrence.word.transcript == id {
            let (start, end) = (word.range.lowerBound, word.range.upperBound)
            if let last = units.last, last.word == word.occurrence.word, last.start == start {
                units[units.count - 1].end = max(last.end, end)
            } else {
                units.append((word.occurrence.word, start, end, word.text))
            }
        }
        let cues = units.filter { $0.end > $0.start }.map { Cue(start: $0.start, end: $0.end, text: $0.text) }
        guard !cues.isEmpty else { throw .noCue(left: units.count) }
        return (cues, units.count - cues.count)
    }
}

/// A subtitle file form, from the extension of its path.
public enum SubtitleFormat: Sendable {
    case srt, vtt

    public init?(pathExtension: String) {
        switch pathExtension.lowercased() {
        case "srt": self = .srt
        case "vtt": self = .vtt
        default: return nil
        }
    }

    /// The file text: UTF-8 with LF line ends, cues in the order given, times in whole
    /// milliseconds (half away from zero), hours of 2 digits or more, and an end after the start.
    /// SRT numbers the cues from 1 and has a comma before the milliseconds. WebVTT has a `WEBVTT`
    /// line and a dot, and escapes `&`, `<`, and `>` in the text. `-->` in a text becomes `->`.
    public func text(_ cues: [Cue], sampleRate: Int) -> String {
        let separator = self == .srt ? "," : "."
        func clock(_ milliseconds: Int) -> String {
            String(
                format: "%02d:%02d:%02d%@%03d", milliseconds / 3_600_000, milliseconds / 60_000 % 60,
                milliseconds / 1000 % 60, separator, milliseconds % 1000)
        }
        func milliseconds(_ frames: Frames) -> Int {
            Int((Double(frames.count) * 1000 / Double(sampleRate)).rounded())
        }
        var blocks: [String] = self == .vtt ? ["WEBVTT"] : []
        for (index, cue) in cues.enumerated() {
            let start = milliseconds(cue.start)
            let end = max(milliseconds(cue.end), start + 1)
            var text = cue.text.replacing("-->", with: "->")
            if self == .vtt {
                text = text.replacing("&", with: "&amp;").replacing("<", with: "&lt;").replacing(">", with: "&gt;")
            }
            blocks.append((self == .srt ? "\(index + 1)\n" : "") + "\(clock(start)) --> \(clock(end))\n\(text)")
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }
}
