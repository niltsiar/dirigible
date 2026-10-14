import Foundation
import Testing

@testable import DirigibleCore

/// The words of a paste (run transcript-1, criterion T15; decision 0042).
struct TranscriptPasteTests {
    /// A source session at `rate` with clip "H" over file "h" and words 1 and 2 of transcript 1.
    func source(rate: Int = 48_000) throws -> Session {
        var session = Session(sampleRate: rate)
        try session.addTrack("host", name: "Host", layout: .mono)
        try session.addFile(AudioFile(id: "h", path: "h.wav", layout: .mono, length: 480_000))
        try session.place(Clip(id: "H", file: "h", start: 0, offset: 0, length: 480_000), on: "host")
        session.addWords([(1, 48_000..<96_000, "Hello"), (2, 96_000..<144_000, "world")], file: "h")
        session.transcripts[TranscriptID(1)]?.name = "episode.json"
        return session
    }

    /// A target at `rate` with one track, and the copy "h2" of file "h" with `length` frames.
    func target(rate: Int = 48_000, length: Frames = 480_000) throws -> Session {
        var session = Session(sampleRate: rate)
        try session.addTrack("t", name: "T", layout: .mono)
        try session.addFile(AudioFile(id: "h2", path: "h2.wav", layout: .mono, length: length))
        return session
    }

    /// The paste of `excerpt` into `target` as `pasteClipboard` makes it: resampled to the target
    /// rate, then mapped to the copy "h2".
    func paste(_ excerpt: Excerpt, into target: inout Session) throws {
        let record = try #require(target.files["h2"])
        var pasted = excerpt
        if excerpt.sampleRate != target.sampleRate {
            pasted = excerpt.resampled(to: target.sampleRate, lengths: ["h": record.length])
        }
        try target.paste(try pasted.mapped(to: ["h": record]), at: 0, on: ["t"])
    }

    /// T15. A paste from another package brings the words of its file to the new record.
    @Test func pasteBringsTheWords() throws {
        var target = try target()
        try paste(try source().excerpt(of: ["H"]), into: &target)

        #expect(target.words().map(\.text) == ["Hello", "world"])
        #expect(target.words().map(\.range) == [48_000..<96_000, 96_000..<144_000])
        #expect(target.transcripts[TranscriptID(1)]?.name == "episode.json")
        let same = try Session(xml: target.checkedData()) == target
        #expect(same, "the target saves")
    }

    /// T15. 48 kHz to 44.1 kHz scales each edge with the rule of `Excerpt.resampled`.
    @Test func pasteAtAnotherRateScalesTheWords() throws {
        var target = try target(rate: 44_100, length: 441_000)
        try paste(try source().excerpt(of: ["H"]), into: &target)

        #expect(target.words().map(\.range) == [44_100..<88_200, 88_200..<132_300])
    }

    /// T15. A paste in one package adds no anchor: the words of the file show under the new clip.
    @Test func pasteInOnePackageAddsNoAnchor() throws {
        var session = try source()
        let transcripts = session.transcripts
        try session.paste(try session.excerpt(of: 0..<200_000, on: ["host"]), at: 480_000, on: ["host"])

        let same = session.transcripts == transcripts
        #expect(same)
        #expect(session.words().map(\.text) == ["Hello", "world", "Hello", "world"])
    }

    /// T15 (plan gate 1 item 9). A target with transcript 1 gets the pasted transcript as number 2,
    /// with its name and word numbers.
    @Test func pasteIntoATargetWithTranscriptOneMakesANewID() throws {
        var target = try target()
        try target.addFile(AudioFile(id: "own", path: "own.wav", layout: .mono, length: 480_000))
        target.addWords([(7, 0..<10, "own")], file: "own")
        try paste(try source().excerpt(of: ["H"]), into: &target)

        #expect(target.transcripts.keys.map(\.number).sorted() == [1, 2])
        #expect(target.transcripts[TranscriptID(2)]?.name == "episode.json")
        #expect(
            target.words().map(\.occurrence.word) == [1, 2].map { WordID(transcript: TranscriptID(2), number: $0) })
    }

    /// T15. Two words whose midpoints differ at 48 kHz get one midpoint at 44.1 kHz: the order
    /// becomes the number order, and the target saves.
    @Test func rateChangeTieKeepsTheOrder() throws {
        var source = try source()
        source.transcripts = [:]
        source.addWords([(2, 1_001..<1_003, "b"), (1, 1_002..<1_004, "a")], file: "h")
        #expect(source.transcripts[TranscriptID(1)]?.words["h"]?.all.map(\.number) == [2, 1])
        var target = try target(rate: 44_100, length: 441_000)
        try paste(try source.excerpt(of: ["H"]), into: &target)

        #expect(target.transcripts[TranscriptID(1)]?.words["h2"]?.all.map(\.number) == [1, 2])
        let same = try Session(xml: target.checkedData()) == target
        #expect(same)
    }
}
