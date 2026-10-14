import Foundation
import Testing

@testable import DirigibleCore

/// The Whisper JSON and WebVTT parsers (run transcript-1, criteria T1 to T3).
struct TranscriptParseTests {
    func parse(_ text: String) throws(TranscriptFileError) -> TranscriptFile {
        try TranscriptFile(data: Data(text.utf8))
    }

    /// T1. The E38 fixture (`scripts/eval/agent-transcript.json`): 11 segments with 95 words.
    @Test func whisperWords() throws {
        let url = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../../scripts/eval/agent-transcript.json")
        let file = try TranscriptFile(data: Data(contentsOf: url))
        #expect(file.units.count == 95 && file.untimed == 0 && !file.cues)
        #expect(
            file.units.prefix(2) == [
                .init(start: 6.0, end: 6.42, text: "Welcome"), .init(start: 6.5, end: 6.75, text: "to"),
            ])
        #expect(file.units.last == .init(start: 80.9, end: 81.22, text: "time."))
        let leading = try parse(
            #"{"segments":[{"start":0,"end":1,"text":" Hi","words":[{"word":" Hi","start":0.1,"end":0.4}]}]}"#)
        #expect(leading.units == [.init(start: 0.1, end: 0.4, text: "Hi")], "the leading space goes")
    }

    /// T1. A segment with no words is one unit with the segment text and times; an empty words array too.
    @Test func whisperSegmentWithNoWords() throws {
        let file = try parse(
            #"{"segments":[{"start":1,"end":2,"text":" One two."},{"start":3,"end":4,"text":"Three","words":[]},"#
                + #"{"start":5,"end":6,"text":"x","words":[{"word":"Four","start":5.1,"end":5.5}]}]}"#)
        #expect(file.units.map(\.text) == ["One two.", "Three", "Four"])
        #expect(file.units.map(\.start) == [1, 3, 5.1])
        #expect(file.cues, "two segments have no word times")
        #expect(try parse(#"{"segments":[{"start":1,"end":2,"text":"One."}]}"#).cues, "no segment has words")
    }

    /// T1. The top-level words of the API win over its segments, which have no words.
    @Test func whisperTopLevelWords() throws {
        let file = try parse(
            #"{"text":"Hi there","segments":[{"start":0,"end":1,"text":"Hi there"}],"#
                + #""words":[{"word":"Hi","start":0,"end":0.4},{"word":"there","start":0.5,"end":1}]}"#)
        #expect(file.units.map(\.text) == ["Hi", "there"])
    }

    /// T1. WhisperX leaves an unaligned word (a numeral) with no start and end: it is dropped and
    /// counted, and the other words stay.
    @Test func whisperXWordWithNoTimeIsSkipped() throws {
        let file = try parse(
            #"{"segments":[{"start":0,"end":2,"text":"In 2024 we","words":[{"word":"In","start":0,"end":0.3,"score":0.9},"#
                + #"{"word":"2024"},{"word":"we","start":1.2,"end":1.5,"score":0.8}]}]}"#)
        #expect(file.units.map(\.text) == ["In", "we"])
        #expect(file.untimed == 1)
    }

    /// T1 and T3. End before start, a negative start, and a cue line that does not parse are units
    /// with no time, in JSON and in WebVTT. Control: an end equal to the start is a usable time.
    @Test func badTimeIsSkipped() throws {
        let json = try parse(
            #"{"words":[{"word":"a","start":2,"end":1},{"word":"b","start":-1,"end":1},"#
                + #"{"word":"c","start":3,"end":3},{"word":"d","start":4,"end":5}]}"#)
        #expect(json.units.map(\.text) == ["c", "d"] && json.untimed == 2, "a word with no length keeps its text")
        let vtt = try parse(
            "WEBVTT\n\n00:01.000 --> 00:00.500\nback\n\n00:0x.000 --> 00:02.000\nbad\n\n00:03.000 --> 00:03.000\nnone\n\n"
                + "00:03.000 --> 00:04.000\ngood\n")
        #expect(vtt.units.map(\.text) == ["none", "good"] && vtt.untimed == 2)
    }

    /// T3. One word with a bad time keeps the file; a file with only bad times is refused.
    @Test func oneBadTimeKeepsTheFile() throws {
        #expect(
            try parse(#"{"words":[{"word":"a","start":2,"end":1},{"word":"b","start":0,"end":1}]}"#).units.count == 1)
        #expect(throws: TranscriptFileError.noTimedWord) {
            try parse(#"{"words":[{"word":"a","start":2,"end":1}]}"#)
        }
    }

    /// T21. The format comes from the content: WEBVTT after a byte order mark is WebVTT; other
    /// text is JSON.
    @Test func formatComesFromTheContent() throws {
        #expect(try parse("\u{FEFF}WEBVTT\n\n00:00.000 --> 00:01.000\nHi\n").units.map(\.text) == ["Hi"])
        #expect(try parse("\u{FEFF}" + #"{"words":[{"word":"Hi","start":0,"end":1}]}"#).units.map(\.text) == ["Hi"])
    }

    /// T2. One unit per cue: the tags go, the lines join, the cue settings and the cue ID are
    /// ignored, and the entities read.
    @Test func vttCues() throws {
        let file = try parse(
            "WEBVTT - Episode 1\nKind: captions\n\n1\n00:00:01.000 --> 00:00:02.500 align:start position:10%\n"
                + "<v Host>Hi there</v>\n<i>everyone</i> &amp; you\n\n00:00:03.000 --> 00:00:04.000\n<v.loud Guest>Hello\n"
        )
        #expect(
            file.units == [
                .init(start: 1, end: 2.5, text: "Hi there everyone & you"), .init(start: 3, end: 4, text: "Hello"),
            ])
        #expect(file.cues)
    }

    /// T2. mm:ss.ttt and hh:mm:ss.ttt, CRLF lines.
    @Test func vttShortTimes() throws {
        let file = try parse("WEBVTT\r\n\r\n01:02.250 --> 01:03.000\r\nA\r\n\r\n01:00:00.000 --> 01:00:01.500\r\nB\r\n")
        #expect(file.units.map(\.start) == [62.25, 3600] && file.units.map(\.end) == [63, 3601.5])
    }

    /// T2. NOTE, STYLE, and REGION blocks give no unit.
    @Test func vttSkipsNoteStyleRegion() throws {
        let file = try parse(
            "WEBVTT\n\nNOTE a --> b in a note\n\nSTYLE\n::cue { color: red }\n\nREGION\nid:r1\n\n"
                + "00:00.000 --> 00:01.000\nOnly\n")
        #expect(file.units.map(\.text) == ["Only"] && file.untimed == 0)
    }

    /// T3. Each refusal names its reason.
    @Test func refusals() {
        for text in ["not a transcript", "[1, 2]", #"{"segments": 3}"#] {
            #expect(throws: TranscriptFileError.unreadable, "\(text)") { try parse(text) }
        }
        for text in ["{}", #"{"segments":[]}"#, "WEBVTT\n", "WEBVTT\n\n00:00.000 --> 00:01.000\n<i></i>\n"] {
            #expect(throws: TranscriptFileError.noTimedWord, "\(text)") { try parse(text) }
        }
        #expect(throws: TranscriptFileError.unreadable) { try TranscriptFile(data: Data([0xFF, 0xFE, 0x00])) }
    }

    /// A tab, a line break, and a control character in a word become one space or go, so the text
    /// is storable in `session.xml`.
    @Test func aTabInAWordBecomesOneSpace() throws {
        let file = try parse(#"{"words":[{"word":" a\tb\n c\u0001d ","start":0,"end":1}]}"#)
        #expect(file.units.map(\.text) == ["a b cd"])
    }
}
