import Foundation
import Testing

@testable import DirigibleCore

/// The cues of a transcript and the SRT and WebVTT text (decision 0061, criterion C11 of run
/// 2026-10-22-take-sync).
struct SubtitlesTests {
    /// C11. A time is whole milliseconds, half away from zero. At 44.1 kHz frame 2 749 437 is
    /// 62 345.98 ms. Control: a truncation gives 00:01:02,345.
    @Test func aTimeRoundsToTheNearestMillisecond() {
        let cue = Cue(start: 2_749_437, end: 2_749_437 + 44_100, text: "Hi")
        #expect(
            SubtitleFormat.srt.text([cue], sampleRate: 44_100)
                == "1\n00:01:02,346 --> 00:01:03,346\nHi\n")
        // Half a millisecond is 24 frames at 48 kHz: 1.5 ms rounds up, 0.5 ms rounds up from 0.
        let half = Cue(start: 72, end: 120, text: "x")
        #expect(SubtitleFormat.vtt.text([half], sampleRate: 48_000) == "WEBVTT\n\n00:00:00.002 --> 00:00:00.003\nx\n")
    }

    /// C11. The end is after the start in milliseconds, also for a cue of a few frames.
    @Test func aShortCueKeepsAnEndAfterTheStart() {
        let cue = Cue(start: 48_000, end: 48_010, text: "uh")
        #expect(SubtitleFormat.srt.text([cue], sampleRate: 48_000) == "1\n00:00:01,000 --> 00:00:01,001\nuh\n")
    }

    /// C11. Hours have two digits or more, SRT numbers the cues from 1, and a text with `-->` reads
    /// `->`. WebVTT escapes `&`, `<`, and `>`.
    @Test func theTextFollowsTheFormRules() {
        let cues = [
            Cue(start: 0, end: 48_000, text: "R&B <now> a --> b"),
            Cue(start: Frames(48_000 * 360_000), end: Frames(48_000 * 360_001), text: "late"),
        ]
        #expect(
            SubtitleFormat.srt.text(cues, sampleRate: 48_000)
                == "1\n00:00:00,000 --> 00:00:01,000\nR&B <now> a -> b\n\n"
                + "2\n100:00:00,000 --> 100:00:01,000\nlate\n")
        #expect(
            SubtitleFormat.vtt.text(cues, sampleRate: 48_000)
                == "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nR&amp;B &lt;now&gt; a -&gt; b\n\n"
                + "100:00:00.000 --> 100:00:01.000\nlate\n")
    }

    /// C11. A word that shows under a clip of each track at one start is one cue, with the later
    /// end. Control: with no dedupe, the cue shows twice.
    @Test func oneWordOnTwoTracksIsOneCue() throws {
        var session = try transcriptSession()
        try session.place(Clip(id: "H", file: "h", start: 0, offset: 0, length: 100_000), on: "host")
        try session.place(Clip(id: "G", file: "h", start: 0, offset: 0, length: 25_000), on: "guest")
        session.addWords([(1, 10_000..<30_000, "Hello"), (2, 40_000..<50_000, "world")], file: "h")

        let (cues, left) = try session.cues(ofTranscript: nil)

        #expect(
            cues == [Cue(start: 10_000, end: 30_000, text: "Hello"), Cue(start: 40_000, end: 50_000, text: "world")])
        #expect(left == 0)
    }

    /// C11. A word with no length is left out and counted, and the transcript choice is checked.
    @Test func theTranscriptChoiceAndTheEmptyRange() throws {
        var session = try transcriptSession()
        try session.place(Clip(id: "H", file: "h", start: 0, offset: 0, length: 100_000), on: "host")
        session.addWords([(1, 10_000..<20_000, "one"), (2, 30_000..<30_000, "none")], file: "h")
        session.addWords([(1, 50_000..<60_000, "other")], file: "h", transcript: 2)

        #expect(throws: SubtitleError.severalTranscripts([1, 2])) { try session.cues(ofTranscript: nil) }
        #expect(throws: SubtitleError.unknownTranscript(3)) { try session.cues(ofTranscript: 3) }
        let (cues, left) = try session.cues(ofTranscript: 1)
        #expect(cues.map(\.text) == ["one"] && left == 1)
        #expect(try session.cues(ofTranscript: 2).cues.map(\.text) == ["other"])
        session.addWords([(1, 5_000..<5_000, "z")], file: "h", transcript: 3)
        #expect(throws: SubtitleError.noCue(left: 1)) { try session.cues(ofTranscript: 3) }
        #expect(throws: SubtitleError.noTranscript) { try Session(sampleRate: 48_000).cues(ofTranscript: nil) }
        #expect(throws: SubtitleError.unknownTranscript(1)) { try Session(sampleRate: 48_000).cues(ofTranscript: 1) }
    }
}
