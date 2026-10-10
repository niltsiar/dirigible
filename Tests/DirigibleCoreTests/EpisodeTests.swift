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

    @Test func anEpisodeNumberIsOneOrMore() throws {
        #expect(try EpisodeNumber(1).value == 1)
        #expect(try EpisodeNumber(text: "12").value == 12)
        expectRefused("1 or more") { _ = try EpisodeNumber(0) }
        expectRefused("1 or more") { _ = try EpisodeNumber(-1) }
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
        #expect(try EpisodeNotes("  a\n\n\tb  ")?.text == "  a\n\n\tb  ")
        #expect(try EpisodeNotes("a\r\nb\rc")?.text == "a\nb\nc")
        expectRefused("control character") { _ = try EpisodeNotes("a\u{1}b") }
    }

    @Test func aWhitespaceOnlyTextIsNoValue() throws {
        for blank in ["", "   ", "\t", " \t\n", "\u{A0}"] {
            #expect(try EpisodeNotes(blank) == nil, "notes \(blank.debugDescription)")
            #expect(try EpisodeLine(blank) == nil, "line \(blank.debugDescription)")
        }
    }

    @Test func anEpisodeWithNoFieldIsEmpty() throws {
        var episode = Episode()
        #expect(episode.isEmpty)
        episode.explicit = true
        #expect(!episode.isEmpty)
        episode = Episode()
        episode.notes = try EpisodeNotes(" \t\n")
        #expect(episode.isEmpty)
    }
}
