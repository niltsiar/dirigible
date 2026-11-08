import Foundation
import Testing

@testable import DirigibleCore

/// The end limit of a follow lane in the ripple edits (decision 0073).
extension FollowRippleTests {
    /// Code gate 3 item 2, limit: a Replace that grows the timeline by 96 000 frames moves the
    /// follow clip c. A last end at `Frames.limit` passes; one frame more throws `.frameOutOfRange`
    /// and changes nothing, the host track included.
    @Test func aReplaceThatMovesAFollowClipEndPastTheLimitRefusesAndChangesNothing() throws {
        let excerpt = try session.excerpt(of: 0..<192_000, on: ["host"])
        let growth = excerpt.length - (Self.cut.upperBound - Self.cut.lowerBound)
        for (end, refuses) in [(Frames.limit, false), (Frames.limit + 1, true)] {
            var edited = session
            let clip = Clip(id: "c", file: "s", start: end - growth - 48_000, offset: 0, length: 48_000)
            try edited.setClips([clip], on: "sfx")
            let before = edited
            if refuses {
                #expect(throws: SessionError.frameOutOfRange) {
                    try edited.replace(Self.cut, with: excerpt, on: ["host"])
                }
                #expect(edited == before)
            } else {
                try edited.replace(Self.cut, with: excerpt, on: ["host"])
                #expect(lane("sfx", in: edited).last?.end == Frames.limit)
            }
        }
    }
}
