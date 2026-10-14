import Foundation
import Testing

@testable import DirigibleCore

/// The import of a transcript through the clips of a track (run transcript-1, criteria T4, T5, T5b).
struct TranscriptImportTests {
    func file(_ json: String) throws -> TranscriptFile { try TranscriptFile(data: Data(json.utf8)) }

    /// `words` as Whisper JSON with top-level words: (text, start, end) in seconds.
    func whisper(_ words: [(String, Double, Double)]) throws -> TranscriptFile {
        try file(
            #"{"words":["#
                + words.map { #"{"word":"\#($0.0)","start":\#($0.1),"end":\#($0.2)}"# }.joined(separator: ",")
                + "]}")
    }

    /// T4. 0.29 s at 48 kHz is 13 920 frames (13 919.999... rounds up), not the floor 13 919.
    @Test func secondsRoundToTheNearestFrame() throws {
        var session = try transcriptSession()
        try session.place(Clip(id: "H", file: "h", start: 0, offset: 0, length: 100_000), on: "host")
        try session.importTranscript(try whisper([("a", 0.29, 0.5)]), name: "t", track: "host", at: 0)
        #expect(session.words().map(\.range) == [13_920..<24_000])
    }

    /// T5. The clip plays file frames 20 000... at timeline 100 000; the export starts at 50 000. A
    /// unit over the clip start is clamped to the clip.
    @Test func wordsMapThroughTheTrackClips() throws {
        var session = try transcriptSession()
        try session.place(Clip(id: "H", file: "h", start: 100_000, offset: 20_000, length: 100_000), on: "host")
        let report = try session.importTranscript(
            try whisper([("over", 1.0, 1.25), ("in", 2.0, 2.5)]), name: "t", track: "host", at: 50_000)

        #expect(report.kept == 2 && report.skipped == 0 && report.untimed == 0)
        let anchors = session.transcripts[report.id]?.words["h"]?.all
        #expect(anchors?.map(\.range) == [20_000..<30_000, 66_000..<90_000], "file frames, clamped to the clip")
        #expect(session.words().map(\.range) == [100_000..<110_000, 146_000..<170_000])
    }

    /// T5. Two clips with a gap; the unit in the gap is skipped and uses up its number. A unit with
    /// no usable time gets no number.
    @Test func wordInAGapIsSkipped() throws {
        var session = try transcriptSession()
        try session.place(Clip(id: "H1", file: "h", start: 0, offset: 0, length: 48_000), on: "host")
        try session.place(Clip(id: "H2", file: "h", start: 96_000, offset: 96_000, length: 48_000), on: "host")
        let data =
            #"{"words":[{"word":"a","start":0.1,"end":0.2},{"word":"none"},{"word":"gap","start":1.2,"end":1.4},"#
            + #"{"word":"b","start":2.1,"end":2.2}]}"#
        let report = try session.importTranscript(try file(data), name: "t", track: "host", at: 0)

        #expect(report.kept == 2 && report.skipped == 1 && report.untimed == 1)
        #expect(session.words().map(\.occurrence.word.number) == [1, 3])
    }

    /// T4 and T3. A unit past `Frames.limit` after the rate conversion counts as untimed.
    @Test func aUnitPastTheLimitIsUntimed() throws {
        var session = try transcriptSession()
        try session.place(Clip(id: "H", file: "h", start: 0, offset: 0, length: 100_000), on: "host")
        let report = try session.importTranscript(
            try whisper([("a", 0.1, 0.2), ("far", 1e12, 1e12 + 1)]), name: "t", track: "host", at: 0)
        #expect(report.kept == 1 && report.untimed == 1 && report.skipped == 0)
    }

    /// Code gate 1 item 4. A word whose start and end round to one frame has no audio: it counts
    /// as untimed.
    @Test func aWordOfNoFrameIsUntimed() throws {
        var session = try transcriptSession()
        try session.place(Clip(id: "H", file: "h", start: 0, offset: 0, length: 100_000), on: "host")
        let report = try session.importTranscript(
            try whisper([("a", 0.1, 0.2), ("short", 1, 1.000_001)]), name: "t", track: "host", at: 0)
        #expect(report.kept == 1 && report.untimed == 1)
    }

    /// Code gate 1 item 6. One file under two clips of the import track: a split shows each word
    /// once; a duplicated region shows each word once under each clip, and a phrase matches there.
    @Test func oneFileUnderTwoClipsGivesEachWordOnce() throws {
        var split = try transcriptSession()
        try split.place(Clip(id: "A", file: "h", start: 0, offset: 0, length: 48_000), on: "host")
        try split.place(Clip(id: "B", file: "h", start: 48_000, offset: 48_000, length: 48_000), on: "host")
        try split.importTranscript(
            try whisper([("hello", 0.5, 0.7), ("world", 1.2, 1.4)]), name: "t", track: "host", at: 0)
        #expect(split.words().map(\.text) == ["hello", "world"])

        var twice = try transcriptSession()
        try twice.place(Clip(id: "A", file: "h", start: 0, offset: 0, length: 96_000), on: "host")
        try twice.place(Clip(id: "C", file: "h", start: 192_000, offset: 0, length: 96_000), on: "host")
        let spoken = [("hello", 0.5, 0.7), ("world", 1.2, 1.4), ("hello", 4.5, 4.7), ("world", 5.2, 5.4)]
        try twice.importTranscript(try whisper(spoken), name: "t", track: "host", at: 0)
        #expect(twice.words().map(\.text) == ["hello", "world", "hello", "world"])
        #expect(twice.words(matching: "hello world").map(\.occurrence.clip) == ["A", "A", "C", "C"])
    }

    /// Code gate 1 item 10. A re-import that empties the last transcript gets a new ID, so a token
    /// of the removed transcript never names a word of the new one.
    @Test func aReimportNeverGivesAnIDAgain() throws {
        var session = try transcriptSession()
        try session.place(Clip(id: "H", file: "h", start: 0, offset: 0, length: 480_000), on: "host")
        try session.importTranscript(try whisper([("a", 0.5, 0.7)]), name: "t", track: "host", at: 0)
        let later = try whisper([("b", 5, 5.5)])
        try session.importTranscript(later, name: "t", track: "host", at: 0)
        let again = try session.importTranscript(later, name: "t", track: "host", at: 0)

        #expect(again.id.number == 3 && session.transcripts.keys.map(\.number).sorted() == [1, 3])
    }

    /// T5b. A second import of the same file replaces the old words: each word shows once.
    /// Control: an import of a later part of the file keeps the old words outside its span.
    @Test func reimportReplacesTheWords() throws {
        var session = try transcriptSession()
        try session.place(Clip(id: "H", file: "h", start: 0, offset: 0, length: 480_000), on: "host")
        let words = try whisper([("a", 1, 1.5), ("b", 2, 2.5), ("c", 3, 3.5)])
        try session.importTranscript(words, name: "t", track: "host", at: 0)
        let second = try session.importTranscript(words, name: "t", track: "host", at: 0)

        #expect(session.words().map(\.text) == ["a", "b", "c"])
        #expect(session.transcripts.keys.map(\.number) == [second.id.number], "the emptied transcript goes")
        try session.importTranscript(try whisper([("C", 3, 3.5)]), name: "u", track: "host", at: 0)
        #expect(session.words().map(\.text) == ["a", "b", "C"])
        #expect(session.transcripts.count == 2)
    }

    /// T5. A transcript with no unit over a clip of the track is refused, and the session stays.
    @Test func noWordOnTheTrackIsRefused() throws {
        var session = try transcriptSession()
        try session.place(Clip(id: "G", file: "g", start: 0, offset: 0, length: 100_000), on: "guest")
        let before = session
        #expect(throws: SessionError.noWordOnTrack("host")) {
            try session.importTranscript(try whisper([("a", 0.1, 0.2)]), name: "t", track: "host", at: 0)
        }
        let same = session == before
        #expect(same)
    }

    /// The session numbers its transcripts from 1.
    @Test func importNumbersTranscriptsFromOne() throws {
        var session = try transcriptSession()
        try session.place(Clip(id: "H", file: "h", start: 0, offset: 0, length: 100_000), on: "host")
        try session.place(Clip(id: "G", file: "g", start: 0, offset: 0, length: 100_000), on: "guest")
        let host = try session.importTranscript(try whisper([("a", 0.1, 0.2)]), name: "host.json", track: "host", at: 0)
        let guest = try session.importTranscript(
            try whisper([("b", 0.1, 0.2)]), name: "guest.json", track: "guest", at: 0)
        #expect(host.id.number == 1 && guest.id.number == 2)
        #expect(session.transcripts[guest.id]?.name == "guest.json")
    }
}
