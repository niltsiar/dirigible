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
}
