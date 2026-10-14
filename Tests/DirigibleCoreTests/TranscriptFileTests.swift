import Foundation
import Testing

@testable import DirigibleCore

/// `session.xml` version 8 with transcripts (run transcript-1, criteria T13 and T14; decision 0055).
struct TranscriptFileTests {
    /// A session with a clip on each track and the words of two transcripts.
    func transcribed() throws -> Session {
        var session = try transcriptSession()
        try session.place(Clip(id: "H", file: "h", start: 0, offset: 0, length: 500_000), on: "host")
        try session.place(Clip(id: "G", file: "g", start: 0, offset: 0, length: 500_000), on: "guest")
        session.addWords([(1, 10_000..<20_000, "Welcome"), (2, 20_000..<30_000, "R&B <now>")], file: "h")
        session.addWords([(1, 40_000..<50_000, "yes")], file: "g", transcript: 2)
        return session
    }

    /// The XML of `session` with `old` replaced by `new` once, read back.
    func read(_ session: Session, replacing old: String, with new: String) throws -> Session {
        let text = String(decoding: session.xmlDocument().xmlData(options: .nodePrettyPrint), as: UTF8.self)
        #expect(text.contains(old), "the fixture holds \(old)")
        return try Session(xml: Data(text.replacing(old, with: new, maxReplacements: 1).utf8))
    }

    /// T13. A session with a transcript writes version 8 and reads back equal, also from the disk.
    @Test func aTranscriptWritesVersion8() throws {
        let session = try transcribed()
        let package = FileManager.default.temporaryDirectory.appending(path: "TranscriptFile-\(UUID())/E.dirigible")
        defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent()) }
        try session.write(to: package)

        let text = try String(contentsOf: package.appending(path: "session.xml"), encoding: .utf8)
        #expect(text.contains(#"version="8""#))
        #expect(text.contains("<words file=\"h\">1 10000 20000 Welcome\n2 20000 30000 R&amp;B &lt;now&gt;</words>"))
        let same = try Session(contentsOf: package) == session
        #expect(same)
    }

    /// T13 (0024 P6). A session with no transcript writes the version of its other data.
    @Test func noTranscriptWritesVersion7() throws {
        var session = try transcribed()
        session.transcripts = [:]
        #expect(session.fileVersion == 1)
        try session.setMarker(Marker(id: "m", name: "M", position: 0, kind: .chapter, url: try WebURL("https://a.b")))
        #expect(session.fileVersion == 7)
        #expect(try transcribed().fileVersion == 8)
    }

    /// T13 (0024 P3). A version 7 reader refuses a version 8 file.
    @Test func version7ReaderRefusesVersion8() throws {
        let data = try transcribed().checkedData()
        #expect(throws: SessionFileError.unsupportedVersion(8)) { try Session(xml: data, newest: 7) }
    }

    /// A `<transcripts>` element in a version 7 file is refused.
    @Test func transcriptsInVersion7AreRefused() throws {
        #expect(throws: SessionFileError.invalidValue(element: "transcripts", attribute: "version")) {
            try read(transcribed(), replacing: #"version="8""#, with: #"version="7""#)
        }
    }

    /// A word past the end of its file is refused; a word that ends at the file end reads.
    @Test func aWordPastTheFileEndIsRefused() throws {
        #expect(throws: SessionFileError.invalidSession(.wordOutsideFile("h"))) {
            try read(transcribed(), replacing: "2 20000 30000", with: "2 20000 1000001")
        }
        #expect(throws: SessionFileError.invalidSession(.wordOutsideFile("h"))) {
            try read(transcribed(), replacing: "2 20000 30000", with: "2 -1 30000")
        }
        #expect(throws: SessionFileError.invalidSession(.wordOutsideFile("h"))) {
            try read(transcribed(), replacing: "2 20000 30000", with: "2 30001 30000")
        }
    }

    @Test func aWordAtTheFileEndReads() throws {
        let read = try read(transcribed(), replacing: "2 20000 30000", with: "2 999000 1000000")
        #expect(read.transcripts[TranscriptID(1)]?.words["h"]?.all.last?.range == 999_000..<1_000_000)
    }

    /// A line with fewer than four fields, a field that is not an integer, a number below 1, or an
    /// empty line is refused.
    @Test func malformedLineIsRefused() throws {
        for line in ["2 20000 30000", "2 20000 x R&amp;B", "x 20000 30000 R&amp;B", "0 20000 30000 R", "\n"] {
            #expect(throws: SessionFileError.invalidValue(element: "words", attribute: "line"), "\(line)") {
                try read(transcribed(), replacing: "2 20000 30000 R&amp;B &lt;now&gt;", with: line)
            }
        }
    }

    /// Two `<words>` of one file in one transcript are refused.
    @Test func oneWordsElementPerFile() throws {
        #expect(throws: SessionFileError.invalidSession(.duplicateID("h"))) {
            try read(
                transcribed(), replacing: "</words>", with: "</words><words file=\"h\">3 60000 70000 more</words>")
        }
    }

    /// A `<words>` of a file that is not in the pool is refused.
    @Test func unknownFileIsRefused() throws {
        #expect(throws: SessionFileError.invalidSession(.unknownFile("nope"))) {
            try read(transcribed(), replacing: #"<words file="h">"#, with: #"<words file="nope">"#)
        }
    }

    /// Two words of one number in one file, an empty text, a transcript ID that is not a number
    /// of 1 or more, and two transcripts of one ID are refused.
    @Test func numbersAndIDsAreChecked() throws {
        #expect(throws: SessionFileError.invalidSession(.duplicateID("1.1"))) {
            try read(transcribed(), replacing: "2 20000 30000", with: "1 20000 30000")
        }
        #expect(throws: SessionFileError.invalidSession(.invalidText(""))) {
            try read(transcribed(), replacing: "2 20000 30000 R&amp;B &lt;now&gt;", with: "2 20000 30000 ")
        }
        for id in ["0", "x"] {
            #expect(throws: SessionFileError.invalidValue(element: "transcript", attribute: "id")) {
                try read(transcribed(), replacing: #"<transcript id="2""#, with: "<transcript id=\"\(id)\"")
            }
        }
        #expect(throws: SessionFileError.invalidSession(.duplicateID("1"))) {
            try read(transcribed(), replacing: #"<transcript id="2""#, with: #"<transcript id="1""#)
        }
    }

    /// T14 (0047). Remove Unused Files takes the words of a removed file from the session and from
    /// each undo entry; transcript 2, with words only in that file, goes. The words of a used file
    /// stay, and the session saves.
    @Test func pruneDropsTheWordsOfARemovedFile() throws {
        var session = try transcribed()
        try session.removeClips(["G"])
        var history = History(session)
        try history.edit { (session: inout Session) throws(SessionError) in
            try session.setGain(Gain(dB: -3)!, track: "host")
        }
        try history.removeUnusedFiles { _ in ["g"] }

        #expect(history.entries.count == 1)
        for value in [history.session] + history.entries {
            #expect(value.transcripts.keys.map(\.number) == [1], "transcript 2 goes with file g")
            #expect(value.transcripts[TranscriptID(1)] == session.transcripts[TranscriptID(1)], "the h words stay")
        }
        let same = try Session(xml: history.session.checkedData()) == history.session
        #expect(same, "the pruned session saves")
    }

    /// T13. "&", "<", a tab that the parser made one space, and a leading space round-trip.
    @Test func ampersandAndTabRoundTrip() throws {
        var session = try transcriptSession()
        try session.place(Clip(id: "H", file: "h", start: 0, offset: 0, length: 500_000), on: "host")
        let file = try TranscriptFile(data: Data(#"{"words":[{"word":" R&B\t<x>","start":0.1,"end":0.2}]}"#.utf8))
        try session.importTranscript(file, name: "a&b <c>.json", track: "host", at: 0)
        session.addWords([(9, 30_000..<40_000, " lead")], file: "h", transcript: 3)
        #expect(session.words().map(\.text) == ["R&B <x>", " lead"])

        let same = try Session(xml: session.checkedData()) == session
        #expect(same)
    }

    /// T13. Overlapping WebVTT cues give anchors with one midpoint: the order (midpoint, then
    /// number) is a property of `Anchors`, so the file reads back equal.
    @Test func overlappingCuesRoundTrip() throws {
        var session = try transcriptSession()
        try session.place(Clip(id: "H", file: "h", start: 0, offset: 0, length: 500_000), on: "host")
        let vtt =
            "WEBVTT\n\n00:02.000 --> 00:04.000\nlong\n\n00:02.500 --> 00:03.500\ninner\n\n00:01.000 --> 00:05.000\nouter\n"
        try session.importTranscript(try TranscriptFile(data: Data(vtt.utf8)), name: "c.vtt", track: "host", at: 0)
        #expect(session.transcripts[TranscriptID(1)]?.words["h"]?.all.map(\.number) == [1, 2, 3])

        let same = try Session(xml: session.checkedData()) == session
        #expect(same)
    }

    /// T13 (seeded): random imports and cuts, then a write and a read, give an equal session.
    @Test func randomTranscriptsRoundTrip() throws {
        var random = SplitMix(seed: 55)
        for _ in 0..<20 {
            var session = try transcriptSession()
            try session.place(Clip(id: "H", file: "h", start: 0, offset: 0, length: 900_000), on: "host")
            try session.place(Clip(id: "G", file: "g", start: 100_000, offset: 0, length: 600_000), on: "guest")
            for track in ["host", "guest"] as [TrackID] {
                var start = 0.0
                let words = (0..<50).map { n in
                    start += Double(Int.random(in: 0...40, using: &random)) / 100
                    let end = start + Double(Int.random(in: 0...60, using: &random)) / 100
                    return #"{"word":"w\#(n)","start":\#(start),"end":\#(end)}"#
                }
                let data = Data(#"{"words":[\#(words.joined(separator: ","))]}"#.utf8)
                try session.importTranscript(try TranscriptFile(data: data), name: "\(track)", track: track, at: 0)
            }
            let shown = session.words()
            let named = shown.indices.filter { _ in Bool.random(using: &random) }.map { shown[$0].occurrence }
            try session.cutWords(named)

            let same = try Session(xml: session.checkedData()) == session
            #expect(same)
        }
    }
}
