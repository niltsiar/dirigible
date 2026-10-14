import Foundation
import Testing

@testable import DirigibleCore

/// The transcript files of decision 0055 (run transcript-1, A10; criteria T13, T22, and T23).
struct TranscriptStoreTests {
    let one = TranscriptID(1)

    /// Clip "H" over file "h" and clip "G" over file "g", and transcript 1 with words in both files.
    func session() throws -> Session {
        var session = try transcriptSession()
        try session.place(Clip(id: "H", file: "h", start: 0, offset: 0, length: 500_000), on: "host")
        try session.place(Clip(id: "G", file: "g", start: 0, offset: 0, length: 500_000), on: "guest")
        session.addWords([(1, 10_000..<20_000, "Hello"), (2, 20_000..<30_000, "there")], file: "h")
        session.addWords([(3, 40_000..<50_000, "yes")], file: "g")
        return session
    }

    /// T22. Each of the five places that changes the words gives a new file name.
    @Test func aChangeOfTheWordsGivesANewName() throws {
        let session = try session()
        let name = try #require(session.transcripts[one]?.file)

        var edited = session
        edited.setWords([Anchor(number: 1, range: 10_000..<20_000, text: "Hello")], file: "h", transcript: one)
        #expect(edited.transcripts[one]?.file != name, "setWords")

        let excerpt = try session.excerpt(of: ["H"])
        let copied = try #require(excerpt.transcripts[one]?.file)
        #expect(copied != name, "Excerpt.init drops the words of g")

        let resampled = excerpt.resampled(to: 44_100, lengths: ["h": 918_750])
        #expect(resampled.transcripts[one]?.file != copied, "Excerpt.resampled")

        let record = AudioFile(id: "h2", path: "h2.wav", layout: .mono, length: 1_000_000)
        let mapped = try excerpt.mapped(to: ["h": record])
        let moved = try #require(mapped.transcripts[one]?.file)
        #expect(moved != copied, "Excerpt.mapped")

        var target = Session(sampleRate: 48_000)
        try target.addTrack("t", name: "T", layout: .mono)
        try target.addFile(record)
        try target.paste(mapped, at: 0, on: ["t"])
        #expect(target.transcripts[one]?.file != moved, "Session.paste")
    }

    /// T22. An assignment of the same words keeps the name, so the session stays equal.
    @Test func anAssignmentOfTheSameWordsKeepsEquality() throws {
        let session = try session()
        var same = session
        let words = try #require(session.transcripts[one]?.words?["h"]?.all)
        same.setWords(words, file: "h", transcript: one)
        #expect(same == session)
    }

    /// T22. A re-import over a span with no old words keeps the name of the old transcript.
    @Test func aReimportWithNoOldWordsKeepsTheName() throws {
        var session = try session()
        let name = try #require(session.transcripts[one]?.file)
        let file = try TranscriptFile(data: Data(#"{"words":[{"word":"late","start":9,"end":9.5}]}"#.utf8))
        try session.importTranscript(file, name: "late.json", track: "host", at: 0)
        #expect(session.transcripts[one]?.file == name)
    }

    /// T13. A transcript file reads back as the words that it was made from: "&", a folded tab,
    /// and overlapping anchors with one midpoint.
    @Test func fileRoundTrip() throws {
        let words: [FileID: Anchors] = [
            "h": Anchors([
                Anchor(number: 1, range: 0..<4_000, text: "R&B <x>"),
                Anchor(number: 2, range: 1_000..<3_000, text: " a b"),
                Anchor(number: 3, range: 1_500..<2_500, text: "inner"),
            ]),
            "g": Anchors([Anchor(number: 9, range: 5..<5, text: "zero")]),
        ]
        let data = TranscriptStore.encode(words)
        #expect(try TranscriptStore.decode(data) == words)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#"version="1""#) && text.contains("R&amp;B &lt;x&gt;"))
    }

    /// A file name is the canonical text of a UUID, so it never holds a path.
    @Test func aFileNameIsACanonicalUUID() {
        let uuid = "6F1C2A0E-0B6D-4E43-9C55-2A51E0C1D7B4"
        #expect(TranscriptFileName(uuid)?.description == uuid)
        for text in ["../x", uuid.lowercased(), uuid + ".xml", "", "/" + uuid] {
            #expect(TranscriptFileName(text) == nil, "\(text)")
        }
        #expect(TranscriptFileName(TranscriptFileName().description) != nil)
    }
}
