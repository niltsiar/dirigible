import Foundation
import Testing

@testable import DirigibleCore

/// The SRT reader (decision 0061, criterion C9 of run 2026-10-22-take-sync). The fixtures are made
/// by hand in the shape that Whisper writes.
extension TranscriptParseTests {
    static let whisperSRT =
        "1\n00:00:01,000 --> 00:00:03,500\n Hello there.\n\n2\n00:00:03,500 --> 00:00:05,120\n How are you?\n\n"
        + "3\n01:02:03,004 --> 01:02:04,000\n Fine, thanks.\n\n"

    /// C9. A Whisper SRT of 3 cues gives one cue unit each, with the times exact to the millisecond.
    @Test func aWhisperSRTReadsEachCue() throws {
        let file = try parse(Self.whisperSRT)
        #expect(
            file.units == [
                .init(start: 1, end: 3.5, text: "Hello there."), .init(start: 3.5, end: 5.12, text: "How are you?"),
                .init(start: 3723.004, end: 3724, text: "Fine, thanks."),
            ])
        #expect(file.cues && file.untimed == 0)
    }

    /// C9. CRLF, CR, and a byte order mark read as LF; the index line is optional; a dot before the
    /// fraction, a short fraction, and a time of one hour digit or of three read.
    @Test func theTolerantVariantsRead() throws {
        let crlf = Self.whisperSRT.replacing("\n", with: "\r\n")
        #expect(try parse(crlf) == parse(Self.whisperSRT), "CRLF")
        #expect(try parse(Self.whisperSRT.replacing("\n", with: "\r")) == parse(Self.whisperSRT), "CR")
        #expect(try parse("\u{FEFF}" + Self.whisperSRT) == parse(Self.whisperSRT), "BOM")
        let loose = try parse(
            "0:00:01.5 --> 0:00:02,25\nNo index.\n\n100:00:00,000 --> 100:00:01,000\nThree hour digits.\n\n"
                + "00:00:04,5 --> 00:00:05,0\nShort fraction.\n")
        #expect(loose.units.map(\.start) == [1.5, 360_000, 4.5])
        #expect(loose.units.map(\.end) == [2.25, 360_001, 5])
        #expect(loose.untimed == 0)
    }

    /// C9. The tags go, two text lines join with one space, a cue with no text is skipped, and a
    /// run of blank lines with white space ends a cue.
    @Test func theTextIsCleaned() throws {
        let file = try parse(
            "1\n00:00:01,000 --> 00:00:02,000\n{\\an8}<i>Top</i> line\nsecond <font color=\"red\">line</font>\n \n"
                + "2\n00:00:02,000 --> 00:00:03,000\n\n\n3\n00:00:03,000 --> 00:00:04,000\nLast\n")
        #expect(file.units.map(\.text) == ["Top line second line", "Last"])
        #expect(file.untimed == 0)
    }

    /// C9. A cue with its end before its start, and a cue whose time does not parse, count as
    /// untimed and the other cues stay.
    @Test func aBadTimeCountsAsUntimed() throws {
        let file = try parse(
            "1\n00:00:02,000 --> 00:00:01,000\nBack\n\n2\n00:00:0x,000 --> 00:00:04,000\nBad\n\n"
                + "3\n00:00:05,000 --> 00:00:06,000\nGood\n")
        #expect(file.units == [.init(start: 5, end: 6, text: "Good")])
        #expect(file.untimed == 2)
    }

    /// C9. The format comes from the content: JSON starts with `{` or `[` after white space and a
    /// byte order mark, WebVTT with `WEBVTT`, and other text is SRT. A JSON file and a WebVTT file
    /// keep their parse.
    @Test func formatComesFromTheFirstCharacter() throws {
        let word = #"{"words":[{"word":"Hi","start":0,"end":1}]}"#
        #expect(try parse("\n  " + word).units.map(\.text) == ["Hi"], "JSON after white space")
        #expect(try parse("\u{FEFF}\n  " + word).units.map(\.text) == ["Hi"], "JSON after a BOM and white space")
        #expect(try parse("WEBVTT\n\n00:01.000 --> 00:02.000\nHi\n").units.map(\.text) == ["Hi"])
        #expect(try !parse(word).cues && parse(Self.whisperSRT).cues)
    }

    /// C9. Text with no timing line is not a transcript; a timing line with no text gives no unit.
    @Test func srtRefusals() {
        for text in ["", "just some notes\nand more", "1\nHello\n"] {
            #expect(throws: TranscriptFileError.unreadable, "\(text)") { try parse(text) }
        }
        for text in ["1\n00:00:01,000 --> 00:00:02,000\n", "1\n00:00:01,000 --> 00:00:02,000\n<i></i>\n"] {
            #expect(throws: TranscriptFileError.noTimedWord, "\(text)") { try parse(text) }
        }
    }
}
