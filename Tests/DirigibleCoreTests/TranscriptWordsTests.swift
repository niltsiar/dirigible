import Foundation
import Testing

@testable import DirigibleCore

/// The words under the clips (run transcript-1, criteria T6 to T8 and T12).
struct TranscriptWordsTests {
    /// T6. A ripple delete before the word moves it left by the removed length; a clip move moves
    /// it; an undo puts it back.
    @Test func wordsFollowRippleAndMove() throws {
        var session = try transcriptSession()
        try session.place(Clip(id: "H", file: "h", start: 10_000, offset: 0, length: 100_000), on: "host")
        session.addWords([(1, 50_000..<60_000, "word")], file: "h")
        var history = History(session)
        #expect(history.session.words().map(\.range) == [60_000..<70_000])

        try history.edit { (session: inout Session) throws(SessionError) in
            try session.rippleDelete([0..<5_000], on: ["host", "guest"], naming: [])
        }
        #expect(history.session.words().map(\.range) == [55_000..<65_000], "a ripple delete moves the word left")
        let moved = try #require(history.session.track("host")?.clips.first?.id)
        try history.edit { (session: inout Session) throws(SessionError) in
            try session.move(moved, to: "guest", start: 200_000)
        }
        #expect(history.session.words().map(\.range) == [250_000..<260_000])
        #expect(history.session.words().map(\.track) == ["guest"], "the word goes with its clip")
        try history.undo()
        try history.undo()
        #expect(history.session.words().map(\.range) == [60_000..<70_000], "undo puts the word back")
    }

    /// T6 limit (plan gate 1 item 6): the words follow only the clips of their files. A move of a
    /// guest clip leaves a host word where it was.
    @Test func wordsFollowOnlyTheImportTrackFiles() throws {
        var session = try transcriptSession()
        try session.place(Clip(id: "H", file: "h", start: 0, offset: 0, length: 100_000), on: "host")
        try session.place(Clip(id: "G", file: "g", start: 0, offset: 0, length: 100_000), on: "guest")
        session.addWords([(1, 50_000..<60_000, "word")], file: "h")

        try session.move("G", to: "guest", start: 30_000)

        #expect(session.words().map(\.range) == [50_000..<60_000])
    }

    /// T7. The clip plays file frames 30 000..<50 000 at timeline 100 000. A word with its midpoint
    /// at the last frame shows, clamped; one frame further it does not. A word over the clip start
    /// shows from the clip start.
    @Test func clipEdgeUsesTheMidpoint() throws {
        var session = try transcriptSession()
        try session.place(Clip(id: "H", file: "h", start: 100_000, offset: 30_000, length: 20_000), on: "host")
        session.addWords(
            [
                (1, 29_000..<31_002, "start"), (2, 49_998..<50_000, "last"), (3, 49_997..<50_002, "edge"),
                (4, 49_999..<50_001, "past"),
            ], file: "h")

        let shown = session.words()
        #expect(shown.map(\.text) == ["start", "edge", "last"])
        #expect(shown.map(\.range) == [100_000..<101_002, 119_997..<120_000, 119_998..<120_000])
    }

    /// T7. A split at the midpoint of a word, or one frame after it, shows the word once, under the
    /// part that holds its midpoint.
    @Test func splitShowsEachWordOnce() throws {
        for (frame, clip, range) in [
            (15_000, "H@15000", 15_000..<20_000), (15_001, "H", 10_000..<15_001),
        ] as [(Frames, ClipID, Range<Frames>)] {
            var session = try transcriptSession()
            try session.place(Clip(id: "H", file: "h", start: 0, offset: 0, length: 100_000), on: "host")
            session.addWords([(1, 10_000..<20_000, "word")], file: "h")
            try session.split("H", at: frame)

            #expect(session.words().map(\.occurrence.clip) == [clip], "split at \(frame)")
            #expect(session.words().map(\.range) == [range], "split at \(frame)")
        }
    }

    /// T8. The word is in the crossfade handle of "L" and in the file range of "R": it shows once,
    /// under "R".
    @Test func crossfadeHandleHidesTheWord() throws {
        var session = try transcriptSession()
        try session.place(Clip(id: "L", file: "h", start: 0, offset: 0, length: 50_000), on: "host")
        try session.place(Clip(id: "R", file: "h", start: 50_000, offset: 50_400, length: 49_600), on: "host")
        try session.setCrossfades(["L": 2_000])
        session.addWords([(1, 50_500..<50_700, "word")], file: "h")

        #expect(session.words().map(\.occurrence.clip) == ["R"])
        #expect(session.words().map(\.range) == [50_100..<50_300])
    }

    /// T12 (library part). A phrase matches whole words of one track, with case, diacritics, and
    /// edge punctuation ignored. "show" does not match "showers".
    @Test func matchFindsAPhrase() throws {
        var session = try transcriptSession()
        try session.place(Clip(id: "H", file: "h", start: 0, offset: 0, length: 200_000), on: "host")
        let texts = ["Welcome", "to", "the", "Show,", "and", "welcome", "to", "Café", "Showers."]
        session.addWords(
            texts.enumerated().map {
                ($0.offset + 1, Frames($0.offset * 10_000)..<Frames($0.offset * 10_000 + 5_000), $0.element)
            },
            file: "h")

        #expect(session.words(matching: "welcome to the show").map(\.text) == ["Welcome", "to", "the", "Show,"])
        #expect(session.words(matching: "WELCOME TO").map(\.occurrence.word.number) == [1, 2, 6, 7])
        #expect(session.words(matching: "to cafe").map(\.text) == ["to", "Café"])
        #expect(session.words(matching: "show").map(\.text) == ["Show,"])
        #expect(session.words(matching: "welcome", on: ["guest"]).isEmpty)
        #expect(session.words(in: 12_000..<25_000).map(\.text) == ["to", "the"], "a range keeps the words it touches")
    }
}
