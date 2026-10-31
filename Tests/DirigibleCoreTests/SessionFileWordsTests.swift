import Foundation
import Testing

@testable import DirigibleCore

/// The words of a transcription job in file frames (decision 0065 D4; run whisper-in-app, criteria
/// C21 and C25).
struct SessionFileWordsTests {
    func words(_ list: [(FileID, Range<Frames>, String)]) throws -> FileWords {
        FileWords(try list.map { try #require(FileWords.Word(file: $0.0, range: $0.1, text: $0.2)) })
    }

    /// The list position gives the number, across files.
    @Test func wordsAnchorToTheirFileFrames() throws {
        var session = try transcriptSession()
        let report = try session.addTranscript(
            try words([("h", 1_000..<2_000, "hola"), ("g", 500..<900, "qué"), ("h", 3_000..<4_000, "tal")]),
            name: "whisper", derived: [])

        #expect(report.kept == 3 && report.skipped == 0)
        #expect(session.transcriptNames.map(\.name) == ["whisper"])
        let id = try #require(report.id)
        #expect(
            session.transcripts[id]?.words?["h"]?.all == [
                Anchor(number: 1, range: 1_000..<2_000, text: "hola"),
                Anchor(number: 3, range: 3_000..<4_000, text: "tal"),
            ])
        #expect(session.transcripts[id]?.words?["g"]?.all == [Anchor(number: 2, range: 500..<900, text: "qué")])
    }

    /// C21. A second job on the same span replaces the words there, the words outside the span
    /// stay, and an undo returns the first words.
    @Test func aSecondJobReplacesTheWordsOfItsSpan() throws {
        var history = History(try transcriptSession())
        let firstWords = try words([
            ("h", 1_000..<2_000, "uno"), ("h", 3_000..<4_000, "dos"), ("h", 50_000..<51_000, "fuera"),
        ])
        let secondWords = try words([("h", 1_500..<2_500, "one"), ("h", 3_200..<4_200, "two")])
        let first = try history.edit { (session: inout Session) throws(SessionError) in
            try session.addTranscript(firstWords, name: "first", derived: [])
        }
        let second = try history.edit { (session: inout Session) throws(SessionError) in
            try session.addTranscript(secondWords, name: "second", derived: [])
        }
        let firstID = try #require(first.id)
        let secondID = try #require(second.id)
        #expect(history.session.transcripts[firstID]?.words?["h"]?.all.map(\.text) == ["fuera"])
        #expect(history.session.transcripts[secondID]?.words?["h"]?.all.map(\.text) == ["one", "two"])

        try history.undo()
        #expect(history.session.transcriptNames.map(\.name) == ["first"])
        #expect(history.session.transcripts[firstID]?.words?["h"]?.all.map(\.text) == ["uno", "dos", "fuera"])
    }

    /// C25. A word of a file that is not in the pool is skipped and uses up its number.
    @Test func aWordOfAFileNotInThePoolUsesUpItsNumber() throws {
        var session = try transcriptSession()
        let report = try session.addTranscript(
            try words([("h", 1_000..<2_000, "a"), ("gone", 0..<500, "b"), ("h", 3_000..<4_000, "c")]),
            name: "t", derived: [])

        #expect(report.kept == 2 && report.skipped == 1)
        #expect(session.transcripts[try #require(report.id)]?.words?["h"]?.all.map(\.number) == [1, 3])
        #expect(session.transcripts[try #require(report.id)]?.words?["gone"] == nil)
    }

    /// C25. The entry (h, h2, span) gives h2 the new words of h in the span, with their numbers,
    /// moved by -(span start), and the old words of another transcript in that span of h2 go. An
    /// entry whose derived file is not in the pool adds nothing.
    @Test func aDerivedEntryCopiesTheNewWordsWithTheirNumbers() throws {
        var session = try transcriptSession()
        try session.addFile(AudioFile(id: "h2", path: "h2.wav", layout: .mono, length: 100_000))
        session.addWords([(1, 15_000..<16_000, "old"), (2, 80_000..<90_000, "keep")], file: "h2")
        let report = try session.addTranscript(
            try words([("h", 210_000..<220_000, "a"), ("h", 250_000..<260_000, "b"), ("h", 500_000..<510_000, "c")]),
            name: "t", derived: [("h", "h2", 200_000..<300_000), ("h", "ghost", 200_000..<300_000)])

        let id = try #require(report.id)
        #expect(report.kept == 3)
        #expect(
            session.transcripts[id]?.words?["h2"]?.all == [
                Anchor(number: 1, range: 10_000..<20_000, text: "a"),
                Anchor(number: 2, range: 50_000..<60_000, text: "b"),
            ])
        #expect(session.transcripts[TranscriptID(1)]?.words?["h2"]?.all.map(\.text) == ["keep"])
        #expect(session.transcripts[id]?.words?.keys.sorted { $0.rawValue < $1.rawValue } == ["h", "h2"])
    }

    /// Decision 0057 D11. A word of a rendered file goes to the root, in root frames, and shows
    /// under a clip of the rendered file. A derived entry of a rendered file copies nothing: the
    /// root holds its words.
    @Test func wordsOfARenderedFileAnchorToItsRoot() throws {
        var session = try transcriptSession()
        let origin = RenderOrigin(
            source: "h", offset: 100_000, treatment: Treatment(.noise(.standard)), addedGain: .zero)
        try session.addFile(AudioFile(id: "r", path: "r.wav", layout: .mono, length: 50_000, origin: origin))
        try session.place(Clip(id: "R", file: "r", start: 0, offset: 0, length: 50_000), on: "host")
        let report = try session.addTranscript(
            try words([("r", 1_000..<2_000, "hola")]), name: "t", derived: [("h", "r", 100_000..<150_000)])

        let id = try #require(report.id)
        #expect(
            session.transcripts[id]?.words?["h"]?.all == [Anchor(number: 1, range: 101_000..<102_000, text: "hola")])
        #expect(session.transcripts[id]?.words?["r"] == nil)
        #expect(session.words().map(\.range) == [1_000..<2_000])
    }

    /// C16 reports 0 words: a job with no kept word adds no transcript and changes nothing.
    @Test func noKeptWordChangesNothing() throws {
        var session = try transcriptSession()
        session.addWords([(1, 1_000..<2_000, "old")], file: "h")
        let before = session
        let report = try session.addTranscript(try words([("gone", 0..<500, "a")]), name: "t", derived: [])

        #expect(report.id == nil && report.kept == 0 && report.skipped == 1)
        #expect(session == before)
    }
}
