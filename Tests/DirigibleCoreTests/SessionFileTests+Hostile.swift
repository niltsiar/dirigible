import Foundation
import Testing

@testable import DirigibleCore

/// A package XML file from another person (decision 0003): the reader refuses deep nesting, each
/// file on which the parser pass stops, and an origin past its source, and it keeps opening each
/// valid prolog.
extension SessionFileTests {
    static let declaration = #"<?xml version="1.0" encoding="UTF-8"?>"#
    static let sessionRoot =
        #"<session xmlns="https://github.com/niltsiar/dirigible/session" version="1" sampleRate="48000">"#

    /// A session with a file, a track, a clip, a marker, and episode notes.
    static func hostileFixture() throws -> Session {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f1", path: "a.wav", layout: .mono, length: 480_000))
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.place(Clip(id: "c1", file: "f1", start: 0, offset: 0, length: 480_000), on: "t1")
        try session.setMarker(Marker(id: "m1", name: "Intro", position: 48_000, kind: .chapter))
        var episode = Episode()
        episode.notes = EpisodeNotes("Notes")
        session.setEpisode(episode)
        return session
    }

    /// The writer output of `session` with its XML declaration replaced by `prolog`.
    static func written(_ session: Session, prolog: String) throws -> Data {
        let text = String(decoding: try session.checkedData(), as: UTF8.self)
        try #require(text.hasPrefix(declaration), "the writer declaration comes first")
        return Data(text.replacing(declaration, with: prolog, maxReplacements: 1).utf8)
    }

    /// An empty session root with `depth - 1` closed unknown elements nested in it.
    static func nested(depth: Int) -> Data {
        let inner = depth - 1
        let text =
            declaration + "\n" + sessionRoot + String(repeating: "<a>", count: inner)
            + String(repeating: "</a>", count: inner) + "</session>\n"
        return Data(text.utf8)
    }

    /// C4, X8 and X9: depth 64 (the root counted as 1) opens equal to the file with no nesting;
    /// depth 65 is refused.
    @Test func depthSixtyFourOpensAndSixtyFiveIsRefused() throws {
        let flat = try Session(xml: Self.nested(depth: 1))

        #expect(try Session(xml: Self.nested(depth: 64)) == flat, "depth 64 opens")
        #expect(throws: SessionFileError.malformedXML, "depth 65") { try Session(xml: Self.nested(depth: 65)) }
    }

    /// C1, X6: a comment and a processing instruction after the declaration open.
    @Test func aPrologCommentAndInstructionOpen() throws {
        let session = try Self.hostileFixture()
        let data = try Self.written(session, prolog: Self.declaration + "\n<!-- x -->\n<?x y?>")

        #expect(try Session(xml: data) == session)
    }

    /// C1, X16: a UTF-8 BOM and a lower-case `utf-8` in one file open.
    @Test func aByteOrderMarkAndLowerCaseUTF8Open() throws {
        let session = try Self.hostileFixture()
        let data =
            try Data([0xEF, 0xBB, 0xBF]) + Self.written(session, prolog: #"<?xml version="1.0" encoding="utf-8"?>"#)

        #expect(try Session(xml: data) == session)
    }

    /// C1, X21: each valid spelling of a UTF-8 declaration opens.
    @Test func aUTF8DeclarationInEachSpellingOpens() throws {
        let session = try Self.hostileFixture()
        let prologs = [
            #"<?xml version="1.0" encoding = 'utf-8'?>"#,
            "<?xml\tversion=\"1.0\" encoding=\"UTF-8\"?>",
            "<?xml version=\"1.0\"\nencoding=\"UTF-8\"?>",
            #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#,
        ]
        for prolog in prologs {
            #expect(try Session(xml: Self.written(session, prolog: prolog)) == session, "\(prolog)")
        }
    }

    /// C4, X24: a track name of 11 MB, over the parser limit of 10,000,000 bytes, is refused.
    @Test func anAttributeOverTheParserLimitIsRefused() throws {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "MARK", layout: .mono)
        let text = String(decoding: try session.checkedData(), as: UTF8.self)
        try #require(text.contains("name=\"MARK\""))
        let data = Data(text.replacing("MARK", with: String(repeating: "n", count: 11_000_000)).utf8)

        #expect(throws: SessionFileError.malformedXML) { try Session(xml: data) }
    }

    /// C6, X10 to X12: the origin of "a NR" (300,000 frames) in "z" (1,000,000 frames) with the
    /// offset `Int.max`, 700,000 (the last range inside the source), and 700,001.
    @Test func anOriginOffsetPastTheSourceIsRefused() throws {
        let session = try renderedBeforeSource()
        let text = String(decoding: try session.checkedData(), as: UTF8.self)
        try #require(text.contains(#"offset="200000""#))
        func read(_ offset: String) throws(SessionFileError) -> Session {
            try Session(xml: Data(text.replacing(#"offset="200000""#, with: #"offset="\#(offset)""#).utf8))
        }

        #expect(throws: SessionFileError.invalidSession(.invalidOrigin("a NR")), "X10") {
            try read("9223372036854775807")
        }
        #expect(try read("700000").files["a NR"]?.origin?.offset == 700_000, "X11")
        #expect(throws: SessionFileError.invalidSession(.invalidOrigin("a NR")), "X12") { try read("700001") }
    }

    /// C7, fuzz seed 20261104 case 112 (M10): a word text with a CR, as `&#13;`, is refused, because
    /// the writer cannot write it back. A word with other text decodes equal.
    @Test func aWordWithAControlCharacterIsRefused() throws {
        let words: [FileID: Anchors] = ["h": Anchors([Anchor(number: 1, range: 0..<10, text: "Café 🎙️")])]
        let text = String(decoding: TranscriptStore.encode(words), as: UTF8.self)
        try #require(text.contains("1 0 10 Café 🎙️"))
        #expect(try TranscriptStore.decode(Data(text.utf8)) == words)

        let carriageReturn = Data(text.replacing("Café 🎙️", with: "a&#13;b").utf8)
        #expect(throws: SessionFileError.invalidValue(element: "words", attribute: "line")) {
            try TranscriptStore.decode(carriageReturn)
        }
    }

    /// C4, X23: 11 MB of episode notes and an 11 MB `<words>` text node open, equal.
    @Test func elevenMegabyteTextNodesOpen() throws {
        var session = Session(sampleRate: 48_000)
        var episode = Episode()
        episode.notes = EpisodeNotes(String(repeating: "n", count: 11_000_000))
        session.setEpisode(episode)
        let data = try session.checkedData()
        #expect(data.count > 11_000_000)
        #expect(try Session(xml: data) == session, "the notes")

        let words: [FileID: Anchors] = [
            "h": Anchors([
                Anchor(number: 1, range: 0..<10, text: String(repeating: "w", count: 11_000_000)),
                Anchor(number: 2, range: 20..<30, text: "end"),
            ])
        ]
        let encoded = TranscriptStore.encode(words)
        #expect(encoded.count > 11_000_000)
        #expect(try TranscriptStore.decode(encoded) == words, "the words")
    }
}
