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
}
