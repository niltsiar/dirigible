import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Run 2026-10-11-ui-polish-header C19: while the take records, its live region draws in the red
/// live palette, as in Hindenburg and Logic. The finalize draws the normal palette, so its pixels
/// equal the clips after the hand-off (premortem fix check 1).
extension TimelineLiveTests {
    @Test func theLiveRegionIsRed() async throws {
        let lanes = try await take()
        lanes.report(0, 1)
        lanes.tick(1.05)
        let palette = lanes.view.lanes.palette
        let live = palette.live
        #expect(live.clip != palette.clip && live.peak != palette.peak && live.rms != palette.rms)
        let colors = Set(try lanes.runs(at: 0.5, lane: 0).map(\.color))
        #expect(colors == [live.clip, live.peak, live.rms], "the live waveform: \(colors)")
        #expect(try lanes.runs(at: 1.03, lane: 0).map(\.color) == [live.clip], "the box to the head")

        lanes.stop(at: 1.05)
        lanes.tick(1.05)
        let finalize = Set(try lanes.runs(at: 0.5, lane: 0).map(\.color))
        #expect(finalize == [palette.clip, palette.peak, palette.rms], "the finalize: \(finalize)")
        await lanes.close()
    }
}
