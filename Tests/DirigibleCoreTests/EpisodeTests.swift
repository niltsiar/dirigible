import Foundation
import Testing

@testable import DirigibleCore

/// The typed episode fields (decision 0045, criterion C3): each type refuses a bad value at the
/// boundary, with a message, and a whitespace-only text is no value.
struct EpisodeTests {
    /// Expects `body` to throw an `EpisodeFieldError` whose message has `text`.
    func expectRefused(
        _ text: String, sourceLocation: SourceLocation = #_sourceLocation,
        _ body: () throws -> Void
    ) {
        do {
            try body()
            Issue.record("no refusal; expected \"\(text)\"", sourceLocation: sourceLocation)
        } catch {
            let message = (error as? EpisodeFieldError)?.message ?? "\(error)"
            #expect(message.contains(text), "message: \(message)", sourceLocation: sourceLocation)
        }
    }

    /// Code gate 1 item 5: an upper bound, so the CLI, the MCP tool, and the pane refuse the same values.
    @Test func anEpisodeNumberIsFrom1To99999() throws {
        #expect(try EpisodeNumber(1).value == 1)
        #expect(try EpisodeNumber(text: "12").value == 12)
        #expect(try EpisodeNumber(99_999).value == 99_999)
        expectRefused("from 1 to 99999, not 0") { _ = try EpisodeNumber(0) }
        expectRefused("from 1 to 99999, not -1") { _ = try EpisodeNumber(-1) }
        expectRefused("from 1 to 99999, not 100000") { _ = try EpisodeNumber(100_000) }
        expectRefused("whole number") { _ = try EpisodeNumber(text: "1.5") }
    }

    @Test func aWebURLIsHTTPOrHTTPSAndASCII() throws {
        #expect(try WebURL("https://a.b/c").text == "https://a.b/c")
        #expect(try WebURL("http://a.b").text == "http://a.b")
        // Foundation gives the punycode host and the percent-encoded path (probe url, macOS 15).
        #expect(try WebURL("https://a.b/café").text == "https://a.b/caf%C3%A9")
        #expect(try WebURL("https://bücher.de").text == "https://xn--bcher-kva.de")
        for bad in ["ftp://a.b", "a.b", "https://", "https://ex ample.com"] {
            expectRefused("http or https URL") { _ = try WebURL(bad) }
        }
    }

    @Test func aCalendarDateIsARealDay() throws {
        #expect(try CalendarDate("2028-02-29").description == "2028-02-29")
        #expect(try CalendarDate("2026-10-10") == CalendarDate(year: 2026, month: 10, day: 10))
        for bad in ["2026-02-30", "2026-13-01", "2026-1-01", "26-10-10", "2026-10-10x"] {
            expectRefused("YYYY-MM-DD") { _ = try CalendarDate(bad) }
        }
    }

    @Test func aLanguageCodeHasThreeLowercaseLettersAndMapsBCodesToTCodes() throws {
        #expect(try LanguageCode("spa").code == "spa")
        #expect(try LanguageCode("fre").code == "fra")
        #expect(try LanguageCode("ger").code == "deu")
        // The reader does not use ICU data: any three lowercase letters pass.
        #expect(try LanguageCode("xxx").code == "xxx")
        for bad in ["es", "xx1", "SPA", "spañ", "span"] {
            expectRefused("three lowercase letters") { _ = try LanguageCode(bad) }
        }
    }

    @Test func aLineHasNoLineBreakAndNoControlCharacter() throws {
        #expect(try EpisodeLine("  Café ñandú ")?.text == "  Café ñandú ")
        expectRefused("one line") { _ = try EpisodeLine("a\nb") }
        expectRefused("one line") { _ = try EpisodeLine("a\tb") }
        expectRefused("control character") { _ = try EpisodeLine("a\u{1}b") }
    }

    @Test func notesKeepLineBreaksAndTabs() throws {
        #expect(EpisodeNotes("  a\n\n\tb  ")?.text == "  a\n\n\tb  ")
        #expect(EpisodeNotes("a\r\nb\rc")?.text == "a\nb\nc")
    }

    /// Code gate 2 item 6: a paste from a PDF can hold control characters that nobody sees. Notes
    /// drop them in place of a refusal; LF and tab stay.
    @Test func notesDropTheInvisibleControlCharacters() {
        #expect(EpisodeNotes("a\u{1}b\u{7F}c\u{1B}d\n\te")?.text == "abcd\n\te")
        #expect(EpisodeNotes("\u{1}\u{2}") == nil, "only control characters is no value")
    }

    @Test func aWhitespaceOnlyTextIsNoValue() throws {
        for blank in ["", "   ", "\t", " \t\n", "\u{A0}"] {
            #expect(EpisodeNotes(blank) == nil, "notes \(blank.debugDescription)")
            #expect(try EpisodeLine(blank) == nil, "line \(blank.debugDescription)")
        }
    }

    @Test func anEpisodeWithNoFieldIsEmpty() throws {
        var episode = Episode()
        #expect(episode.isEmpty)
        episode.explicit = true
        #expect(!episode.isEmpty)
        episode = Episode()
        episode.notes = EpisodeNotes(" \t\n")
        #expect(episode.isEmpty)
    }
}

/// The name of an artwork file in `Artwork/` (decision 0045, criterion C4).
struct ArtworkNameTests {
    @Test func aUUIDWithJPGOrPNGIsAName() throws {
        let name = try ArtworkName("0B3C5B2E-6F1A-4D2B-9E57-1C8F2A9D4E60.jpg")
        #expect(name.path == "Artwork/0B3C5B2E-6F1A-4D2B-9E57-1C8F2A9D4E60.jpg" && !name.isPNG)
        #expect(try ArtworkName("0B3C5B2E-6F1A-4D2B-9E57-1C8F2A9D4E60.png").isPNG)
        #expect(ArtworkName(png: true).isPNG && !ArtworkName(png: false).isPNG)
    }

    @Test func anotherNameIsRefused() {
        for text in [
            "../0B3C5B2E-6F1A-4D2B-9E57-1C8F2A9D4E60.jpg", "0B3C5B2E-6F1A-4D2B-9E57-1C8F2A9D4E60.gif", "cover.jpg",
            "0B3C5B2E-6F1A-4D2B-9E57-1C8F2A9D4E60.jpg.tmp", "",
        ] {
            #expect(throws: EpisodeFieldError(message: "\"\(text)\" is not an artwork file name.")) {
                try ArtworkName(text)
            }
        }
    }
}

/// The one text rule of the pane, the CLI, and the MCP tool (code gate item 3).
struct EpisodeFieldTextTests {
    @Test func eachFieldSetsAndShowsItsText() throws {
        var episode = Episode()
        let cases: [(EpisodeField, String, String)] = [
            (.title, "Café", "Café"), (.show, "Show", "Show"), (.author, "Ana", "Ana"), (.season, " 3 ", "3"),
            (.number, "12", "12"), (.date, "2026-10-09", "2026-10-09"), (.language, "fre", "fra"),
            (.copyright, "© Ana", "© Ana"), (.summary, "a\r\nb", "a\nb"), (.notes, "x\ty", "x\ty"),
            (.episodeURL, "https://a.example/1", "https://a.example/1"),
            (.feedURL, "https://a.example/feed", "https://a.example/feed"), (.guid, "urn:1", "urn:1"),
        ]
        for (field, text, shown) in cases {
            try episode.set(field, text: text)
            #expect(episode.text(of: field) == shown, "\(field)")
        }
        for (field, _, _) in cases {
            try episode.set(field, text: "  ")
            #expect(episode.text(of: field) == "", "a blank text clears \(field)")
        }
        #expect(episode.isEmpty)
    }

    @Test func aBadTextThrowsAndChangesNothing() {
        var episode = Episode()
        #expect(throws: EpisodeFieldError(message: "An episode or season number is from 1 to 99999, not 0.")) {
            try episode.set(.number, text: "0")
        }
        #expect(throws: EpisodeFieldError(message: "\"x\" is not an http or https URL.")) {
            try episode.set(.feedURL, text: "x")
        }
        #expect(episode.isEmpty)
    }
}

/// Code gate 1 item 2: a vertical tab or a form feed in pasted notes is a line break.
@Test func notesTakeAVerticalTabOrAFormFeedAsALineBreak() throws {
    #expect(EpisodeNotes("a\u{0B}b\u{0C}c")?.text == "a\nb\nc")
}
