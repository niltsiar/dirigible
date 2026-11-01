import Foundation
import Testing

@testable import DirigibleCore

/// The frame mapping of Rule M (decision 0037), which the markers and the playhead share.
extension RippleTests {
    /// Rule M: a frame after a cut moves left by the cut, a frame in a cut goes to its start, and a
    /// frame at the start of a cut stays.
    @Test func aFrameMovesByTheCutsBeforeIt() {
        let cuts: [Range<Frames>] = [100..<150, 200..<210]
        let moved = [0, 99, 100, 120, 150, 199, 200, 205, 210, 400].map { Frames($0).afterRippleDelete(of: cuts) }
        #expect(moved == [0, 99, 100, 100, 100, 149, 150, 150, 150, 340].map { Frames($0) }, "\(moved)")
        #expect(Frames(7).afterRippleDelete(of: []) == 7)
    }
}
