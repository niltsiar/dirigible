import Foundation
import Testing

@testable import DirigibleCore

/// The cut of words (run transcript-1, criteria T9 to T11).
struct TranscriptCutTests {
    /// T9. Clip "B" is a copy of clip "A" at 200 000. A cut of words 2 and 3 under "A" removes
    /// 20 000..<50 000; "B" keeps its four words and its audio range, and moves left by 30 000.
    @Test func cutOneOccurrenceKeepsTheOther() throws {
        var session = try transcriptSession()
        try session.place(Clip(id: "A", file: "h", start: 0, offset: 0, length: 100_000), on: "host")
        try session.place(Clip(id: "B", file: "h", start: 200_000, offset: 0, length: 100_000), on: "host")
        session.addWords(
            [
                (1, 10_000..<20_000, "one"), (2, 20_000..<30_000, "two"), (3, 40_000..<50_000, "three"),
                (4, 60_000..<70_000, "four"),
            ], file: "h")
        #expect(session.numbers(under: "A") == [1, 2, 3, 4] && session.numbers(under: "B") == [1, 2, 3, 4])

        let named = session.occurrences([2, 3]).filter { $0.clip == "A" }
        let ranges = try session.cutWords(named)

        #expect(ranges == [20_000..<50_000])
        let clipB = session.clip("B")?.clip
        #expect(clipB?.start == 170_000 && clipB?.offset == 0 && clipB?.length == 100_000, "B keeps its audio")
        #expect(
            session.words().filter { $0.occurrence.clip == "B" }.map(\.range)
                == [180_000..<190_000, 190_000..<200_000, 210_000..<220_000, 230_000..<240_000],
            "B lists all its words, moved only by the ripple")
        #expect(session.words().map(\.occurrence.word.number) == [1, 4, 1, 2, 3, 4])
    }

    /// T10. Two runs on the host file; the guest clip shrinks by the same frames, so the tracks stay
    /// in sync. Control: the ranges come back, and the audio is gone on both tracks.
    @Test func cutsRunsOnAllTracks() throws {
        var session = try transcriptSession()
        try session.place(Clip(id: "H", file: "h", start: 0, offset: 0, length: 200_000), on: "host")
        try session.place(Clip(id: "G", file: "g", start: 0, offset: 0, length: 200_000), on: "guest")
        session.addWords(
            [
                (1, 10_000..<20_000, "a"), (2, 20_000..<30_000, "b"), (3, 30_000..<40_000, "c"),
                (4, 100_000..<110_000, "d"), (5, 110_000..<120_000, "e"), (6, 150_000..<160_000, "f"),
            ], file: "h")

        let ranges = try session.cutWords(session.occurrences([2, 3, 5]))

        #expect(ranges == [20_000..<40_000, 110_000..<120_000])
        #expect(session.end == 170_000, "the session is 30 000 frames shorter")
        for track in ["host", "guest"] as [TrackID] {
            #expect(
                session.track(track)?.clips.map(\.range) == [0..<20_000, 20_000..<90_000, 90_000..<170_000],
                "track \(track) loses the same frames")
        }
        #expect(session.words().map(\.occurrence.word.number) == [1, 4, 6])
        #expect(session.words().map(\.range.lowerBound) == [10_000, 80_000, 120_000])
    }

    /// T10. A guest word between two named host words splits the run, so the cut keeps it.
    /// Control: with no guest word, the same words cut as one range.
    @Test func otherTrackWordSplitsARun() throws {
        var session = try transcriptSession()
        try session.place(Clip(id: "H", file: "h", start: 0, offset: 0, length: 100_000), on: "host")
        try session.place(Clip(id: "G", file: "g", start: 0, offset: 0, length: 100_000), on: "guest")
        session.addWords(
            [(1, 10_000..<20_000, "a"), (2, 20_000..<30_000, "b"), (3, 40_000..<50_000, "c")], file: "h")
        var alone = session
        session.addWords([(1, 30_000..<40_000, "yes")], file: "g", transcript: 2)

        #expect(try alone.cutWords(alone.occurrences([1, 2, 3])) == [10_000..<50_000])
        #expect(try session.cutWords(session.occurrences([1, 2, 3])) == [10_000..<30_000, 40_000..<50_000])
        #expect(session.words().map(\.text) == ["yes"], "the guest word stays")
    }

    /// T10. Word 2 was skipped at import (no host clip under it): numbers 1 and 3 do not follow
    /// each other, so the guest audio in the host gap stays.
    @Test func skippedWordSplitsARun() throws {
        var session = try transcriptSession()
        try session.place(Clip(id: "H1", file: "h", start: 0, offset: 0, length: 20_000), on: "host")
        try session.place(Clip(id: "H2", file: "h", start: 40_000, offset: 40_000, length: 20_000), on: "host")
        try session.place(Clip(id: "G", file: "g", start: 0, offset: 0, length: 60_000), on: "guest")
        session.addWords([(1, 10_000..<20_000, "a"), (3, 40_000..<50_000, "c")], file: "h")

        #expect(try session.cutWords(session.occurrences([1, 3])) == [10_000..<20_000, 40_000..<50_000])
        #expect(session.track("guest")?.clips.map(\.range) == [0..<10_000, 10_000..<30_000, 30_000..<40_000])
    }

    /// T10 limit (plan gate 2 item 5): a skipped word between two touching words splits the runs,
    /// and the ripple delete merges the two ranges, as one range would cut.
    @Test func skippedWordBetweenTouchingNeighboursMerges() throws {
        var session = try transcriptSession()
        try session.place(Clip(id: "H", file: "h", start: 0, offset: 0, length: 100_000), on: "host")
        session.addWords([(1, 10_000..<20_000, "a"), (3, 20_000..<30_000, "c")], file: "h")
        var oneRange = session
        try oneRange.rippleDelete([10_000..<30_000], on: ["host", "guest"])

        #expect(try session.cutWords(session.occurrences([1, 3])) == [10_000..<20_000, 20_000..<30_000])
        let same = session == oneRange
        #expect(same, "the touching ranges cut as one range")
    }

    /// T10 (plan gate 2 item 3): one file on two tracks shows each word twice at one start; a cut of
    /// the host words is one range. Control: a step rule by occurrence cuts three ranges.
    @Test func oneFileOnTwoTracksCutsAsOneRange() throws {
        var session = try transcriptSession()
        try session.place(Clip(id: "H", file: "h", start: 0, offset: 0, length: 100_000), on: "host")
        try session.place(Clip(id: "H2", file: "h", start: 0, offset: 0, length: 100_000), on: "guest")
        session.addWords(
            [(1, 10_000..<20_000, "a"), (2, 20_000..<30_000, "b"), (3, 30_000..<40_000, "c")], file: "h")
        #expect(session.words().count == 6)

        #expect(try session.cutWords(session.occurrences([1, 2, 3])) == [10_000..<40_000])
        #expect(session.words().isEmpty)
    }

    /// T11. An occurrence that the last cut removed, and one of an unknown clip, are refused with
    /// no change.
    @Test func staleOccurrenceIsRefused() throws {
        var session = try transcriptSession()
        try session.place(Clip(id: "H", file: "h", start: 0, offset: 0, length: 100_000), on: "host")
        session.addWords([(1, 10_000..<20_000, "a"), (2, 50_000..<60_000, "b")], file: "h")
        let first = session.occurrences([1])
        try session.cutWords(first)
        let before = session

        #expect(throws: SessionError.unknownWord(first[0])) { try session.cutWords(first + session.occurrences([2])) }
        let unknown = WordOccurrence("1.2.50000@nothing")!
        #expect(throws: SessionError.unknownWord(unknown)) { try session.cutWords([unknown]) }
        let same = session == before
        #expect(same, "a refused cut changes nothing")
        #expect(session.words().count == 1, "the fixture still shows word 2")
    }

    /// T11 (plan gate 1 item 7): a replace gives word 1 an anchor at another file start; the token
    /// from before the replace is refused. Control: the token of the new anchor cuts.
    @Test func tokenFromBeforeAReplaceIsRefused() throws {
        var session = try transcriptSession()
        try session.place(Clip(id: "H", file: "h", start: 0, offset: 0, length: 100_000), on: "host")
        session.addWords([(1, 10_000..<20_000, "a")], file: "h")
        let old = session.occurrences([1])
        session.transcripts[TranscriptID(1)]?.words["h"] = Anchors([
            Anchor(number: 1, range: 12_000..<20_000, text: "a")
        ])

        #expect(throws: SessionError.unknownWord(old[0])) { try session.cutWords(old) }
        #expect(try session.cutWords(session.occurrences([1])) == [12_000..<20_000])
    }

    /// T1 and T10 (plan gate 2 item 1): WhisperX leaves the numeral "2024" with no time. It gets no
    /// number, so the sentence cuts as one range, and the phrase around it matches.
    @Test func untimedWordDoesNotSplitARun() throws {
        var session = try transcriptSession()
        try session.place(Clip(id: "H", file: "h", start: 0, offset: 0, length: 480_000), on: "host")
        let json =
            #"{"segments":[{"start":1,"end":3,"text":"In 2024 we won","words":[{"word":"In","start":1,"end":1.2},"#
            + #"{"word":"2024"},{"word":"we","start":1.8,"end":2},{"word":"won","start":2.1,"end":2.5}]}]}"#
        let report = try session.importTranscript(
            try TranscriptFile(data: Data(json.utf8)), name: "x.json", track: "host", at: 0)
        #expect(report.kept == 3 && report.untimed == 1)

        #expect(session.words(matching: "in we won").map(\.text) == ["In", "we", "won"])
        #expect(try session.cutWords(session.occurrences([1, 2, 3])) == [48_000..<120_000])
    }
}

/// The text of an occurrence token.
struct WordOccurrenceTests {
    @Test func textRoundTrip() throws {
        let text = "1.12.288000@take1.host@5"
        let occurrence = try #require(WordOccurrence(text))
        #expect(occurrence.word.transcript.number == 1 && occurrence.word.number == 12)
        #expect(occurrence.fileStart == 288_000 && occurrence.clip == "take1.host@5")
        #expect(occurrence.description == text)
        for bad in ["1.12@x", "0.1.0@x", "1.0.0@x", "1.1.-5@x", "1.1.0@", "1.1.0", "a.1.0@x", "1.1.1.0@x"] {
            #expect(WordOccurrence(bad) == nil, "\(bad) is refused")
        }
    }
}
