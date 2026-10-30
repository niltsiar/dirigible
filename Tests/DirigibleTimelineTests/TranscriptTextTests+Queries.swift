import DirigibleCore
import Foundation
import Testing

@testable import DirigibleTimeline

extension TranscriptTextTests {
    /// P1. The current paragraph is the last one whose first unit starts at or before the frame,
    /// else the first one. A backchannel line does not start a paragraph.
    @Test func paragraphStartAtAFrame() throws {
        let session = try Self.session([
            Voice(
                "host", "Host",
                [
                    (48_000, 72_000, "Hello"), (288_000, 312_000, "Second"), (312_000, 336_000, "part"),
                    (528_000, 552_000, "Third"),
                ]),
            Voice("guest", "Guest", [(300_000, 310_000, "Mm-hm")]),
        ])
        let text = TranscriptText(session: session)
        func word(at frame: Frames) -> String? {
            text.paragraphStart(at: frame).map { start in
                let rest = (text.string as NSString).substring(from: start)
                return String(rest.prefix { !$0.isWhitespace && $0 != "\n" })
            }
        }
        #expect(word(at: 10) == "Hello", "before the first unit")
        #expect(word(at: 300_000) == "Second", "inside a unit of paragraph 2")
        #expect(word(at: 400_000) == "Second", "in the gap after paragraph 2")
        #expect(word(at: 528_000) == "Third", "at the start of paragraph 3")
        #expect(TranscriptText(session: Session(sampleRate: 48_000)).paragraphStart(at: 0) == nil, "no unit")
    }

    /// P5: the hit test of a click. A unit gives itself, also in a backchannel line. A header, a
    /// backchannel track name, and the line break after a paragraph give none.
    @Test func unitAtATextLocation() throws {
        let text = TranscriptText(
            session: try Self.session([
                Voice("host", "Host", [(0, 24_000, "so"), (48_000, 72_000, "right")]),
                Voice("guest", "Guest", [(30_000, 40_000, "Mm-hm.")]),
            ]))
        let header = try #require(text.headers.first)
        let line = try #require(text.backchannels.first)
        let first = try #require(text.units.first)
        let last = try #require(text.units.last)

        #expect(text.unit(atTextLocation: first.text.lowerBound)?.text == first.text)
        #expect(text.unit(atTextLocation: first.text.upperBound - 1)?.text == first.text)
        #expect(text.unit(atTextLocation: header.range.lowerBound) == nil)
        #expect(text.unit(atTextLocation: line.name.lowerBound) == nil)
        let mm = try #require(text.units.first { $0.track == "guest" })
        #expect(text.unit(atTextLocation: mm.text.lowerBound)?.track == "guest")
        #expect(text.unit(atTextLocation: last.text.upperBound) == nil)
        #expect(text.unit(atTextLocation: text.string.utf16.count + 5) == nil)
    }

    /// P21: the first unit of the paragraph of a header, for an insertion point in the header text
    /// or at its end. A unit, a backchannel line, and a location past the text give none.
    @Test func firstUnitOfTheHeaderParagraph() throws {
        let text = TranscriptText(
            session: try Self.session([
                Voice("host", "Host", [(0, 24_000, "so"), (48_000, 72_000, "now"), (240_000, 264_000, "again")]),
                Voice("guest", "Guest", [(30_000, 40_000, "Mm-hm.")]),
            ]))
        try #require(text.headers.count == 2)
        let (one, two) = (text.headers[0], text.headers[1])
        let so = try #require(text.units.first { $0.frames.lowerBound == 0 })
        let again = try #require(text.units.first { $0.frames.lowerBound == 240_000 })

        #expect(text.headerUnit(atTextLocation: one.range.lowerBound)?.frames == so.frames)
        #expect(text.headerUnit(atTextLocation: one.range.upperBound)?.frames == so.frames, "the end of the header")
        #expect(text.headerUnit(atTextLocation: two.range.lowerBound + 2)?.frames == again.frames)
        #expect(text.headerUnit(atTextLocation: so.text.lowerBound) == nil, "a unit")
        let line = try #require(text.backchannels.first)
        #expect(text.headerUnit(atTextLocation: line.name.lowerBound) == nil, "a backchannel line")
        #expect(text.headerUnit(atTextLocation: text.string.utf16.count + 5) == nil, "past the text")
    }

    // MARK: Slice 13 (P8, P9, P16)

    /// Host "so right" and "again." in two paragraphs, a guest backchannel "Mm-hm." in the first.
    static func selectionText() throws -> TranscriptText {
        TranscriptText(
            session: try session([
                Voice("host", "Host", [(0, 24_000, "so"), (48_000, 72_000, "right"), (240_000, 264_000, "again.")]),
                Voice("guest", "Guest", [(30_000, 40_000, "Mm-hm.")]),
            ]))
    }

    /// P9: a text range snaps to the whole units that it touches, in one range. A range inside a
    /// header, a backchannel track name, or a line break, and a collapsed range, give none.
    @Test func snapsToWholeUnits() throws {
        let text = try Self.selectionText()
        let so = try #require(text.units.first { Self.slice(text, $0.text) == "so" })
        let right = try #require(text.units.first { Self.slice(text, $0.text) == "right" })
        let again = try #require(text.units.first { Self.slice(text, $0.text) == "again." })
        let header = try #require(text.headers.last)
        let line = try #require(text.backchannels.first)

        #expect(
            text.snapped(so.text.lowerBound + 1..<right.text.lowerBound + 1) == so.text
                .lowerBound..<right.text.upperBound)
        #expect(
            text.snapped(right.text.upperBound - 1..<again.text.lowerBound + 1) == right.text
                .lowerBound..<again.text.upperBound)
        #expect(text.snapped(so.text.upperBound..<so.text.upperBound + 1) == nil, "the space between two units")
        #expect(text.snapped(header.range) == nil, "a header only")
        #expect(text.snapped(line.name) == nil, "a backchannel track name only")
        #expect(text.snapped(so.text.lowerBound + 1..<so.text.lowerBound + 1) == nil, "a collapsed range")
    }

    /// P9: the frames of a text range go from the earliest start to the latest end of its units,
    /// so a long cue in the middle that ends after the last unit sets the end.
    @Test func framesOfARangeUseTheLatestEnd() throws {
        let text = TranscriptText(
            session: try Self.session([
                Voice("host", "Host", [(0, 24_000, "one"), (48_000, 72_000, "two")]),
                Voice("guest", "Guest", [(30_000, 200_000, "long")]),
            ]))
        let all = 0..<text.string.utf16.count
        #expect(text.frames(inText: all) == 0..<200_000)
        let two = try #require(text.units.first { Self.slice(text, $0.text) == "two" })
        #expect(text.frames(inText: two.text) == 48_000..<72_000)
        #expect(text.frames(inText: try #require(text.headers.first).range) == nil)
    }

    /// P8: a sentence ends at a unit whose text ends in a period, a question mark, an exclamation
    /// mark, or an ellipsis, or at the last unit of a line. A boundary is the index of the unit
    /// after it; the moves skip a boundary that the selection already ends on.
    @Test func sentenceBoundaries() throws {
        let text = TranscriptText(
            session: try Self.session([
                Voice(
                    "host", "Host",
                    [
                        (0, 1_000, "Is"), (1_000, 2_000, "it?"), (2_000, 3_000, "Yes!"), (3_000, 4_000, "Well\u{2026}"),
                        (4_000, 5_000, "no"), (5_000, 6_000, "end"), (200_000, 201_000, "Next"),
                    ])
            ]))
        try #require(text.units.count == 7)
        #expect(text.nextSentenceBoundary(after: 0) == 2, "after it?")
        #expect(text.nextSentenceBoundary(after: 2) == 3, "after Yes!")
        #expect(text.nextSentenceBoundary(after: 3) == 4, "after the ellipsis")
        #expect(text.nextSentenceBoundary(after: 4) == 6, "the paragraph end")
        #expect(text.nextSentenceBoundary(after: 6) == 7, "the last line end")
        #expect(text.nextSentenceBoundary(after: 7) == 7, "no unit after the end")
        #expect(text.previousSentenceBoundary(before: 6) == 4)
        #expect(text.previousSentenceBoundary(before: 4) == 3)
        #expect(text.previousSentenceBoundary(before: 2) == 0, "no end before it?")
        #expect(text.previousSentenceBoundary(before: 0) == 0)
    }

    /// P9: a range tints each unit of a range track whose midpoint is inside the range. The tint
    /// is one text range for each run of adjacent units on one line.
    @Test func tintedUnitsOfARange() throws {
        let text = try Self.selectionText()
        let so = try #require(text.units.first { Self.slice(text, $0.text) == "so" })
        let right = try #require(text.units.first { Self.slice(text, $0.text) == "right" })
        let mm = try #require(text.units.first { $0.track == "guest" })
        let both: Set<TrackID> = ["host", "guest"]

        // The midpoint of "right" is 60 000.
        #expect(text.tintRuns(0..<60_001, tracks: ["host"]) == [so.text.lowerBound..<right.text.upperBound])
        #expect(text.tintRuns(0..<60_000, tracks: ["host"]) == [so.text], "a midpoint at the range end is out")
        #expect(text.tintRuns(0..<60_001, tracks: both) == [so.text.lowerBound..<right.text.upperBound, mm.text])
        #expect(text.tintRuns(0..<60_001, tracks: ["other"]).isEmpty, "a track outside the range")
    }

    /// P16: the text of a range: the tinted units in text order, one space apart, a line break
    /// between paragraphs and before a backchannel line, with no header and no track name.
    @Test func copyTextOfARange() throws {
        let text = try Self.selectionText()
        #expect(text.copyText(0..<300_000, tracks: ["host", "guest"]) == "so right\nMm-hm.\nagain.")
        #expect(text.copyText(40_000..<300_000, tracks: ["host"]) == "right\nagain.")
        #expect(text.copyText(100_000..<200_000, tracks: ["host", "guest"]) == nil, "a range with no unit")
    }
}
