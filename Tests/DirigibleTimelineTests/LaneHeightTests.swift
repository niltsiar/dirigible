import Testing

@testable import DirigibleTimeline

/// Timeline-navigation criterion N13: the automatic height, and the steps of Taller and Shorter.
struct LaneHeightTests {
    @Test func theStepsGoToTheNextStep() {
        #expect(LaneHeight.automatic.taller(than: 93) == .fixed(100), "taller from 93 is 100")
        #expect(LaneHeight.automatic.shorter(than: 93) == .fixed(80), "shorter from 93 is 80")
        let steps: [Double] = [40, 50, 60, 80, 100, 120, 160, 200]
        #expect(LaneHeight.steps == steps)
        for (low, high) in zip(steps, steps.dropFirst()) {
            #expect(LaneHeight.fixed(low).taller(than: low) == .fixed(high), "taller from \(low)")
            #expect(LaneHeight.fixed(high).shorter(than: high) == .fixed(low), "shorter from \(high)")
        }
        #expect(LaneHeight.fixed(200).taller(than: 200) == .fixed(200), "200 pt is the tallest")
        #expect(LaneHeight.fixed(40).shorter(than: 40) == .fixed(40), "40 pt is the shortest")
    }

    /// The automatic height of 0017: the free height over the tracks, 40 to 120 pt, whole points.
    @Test func theAutomaticHeightSharesTheFreeHeight() {
        #expect(LaneHeight.automatic.points(free: 555, tracks: 6) == 92, "the height is whole points")
        #expect(LaneHeight.automatic.points(free: 1000, tracks: 2) == 120)
        #expect(LaneHeight.automatic.points(free: 300, tracks: 20) == 40)
        #expect(LaneHeight.automatic.points(free: 300, tracks: 0) == 120)
        #expect(LaneHeight.fixed(160).points(free: 300, tracks: 20) == 160)
    }
}
