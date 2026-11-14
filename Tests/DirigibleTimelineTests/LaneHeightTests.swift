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

    /// The automatic height of 0017: the free height over the tracks, 40 to 200 pt, whole points.
    /// Run 2026-10-11-ui-polish-header B2.2: 120 pt left 2 tracks small in a tall window.
    @Test func theAutomaticHeightSharesTheFreeHeight() {
        #expect(LaneHeight.automatic.points(free: 555, tracks: 6) == 92, "the height is whole points")
        #expect(LaneHeight.automatic.points(free: 1000, tracks: 2) == 200)
        #expect(LaneHeight.automatic.points(free: 399, tracks: 2) == 199, "under the cap")
        #expect(LaneHeight.automatic.points(free: 1000, tracks: 10) == 100)
        #expect(LaneHeight.automatic.points(free: 300, tracks: 20) == 40)
        #expect(LaneHeight.automatic.points(free: 300, tracks: 0) == 200)
        #expect(LaneHeight.fixed(160).points(free: 300, tracks: 20) == 160)
    }

    /// Timeline-clarity C4: a lane counts as in view when half of its height or more shows. Lanes
    /// of 40 pt, 5 lanes from 0 to 200 pt.
    @Test func aLaneCountsInViewFromHalfItsHeight() throws {
        let geometry = try #require(
            LaneGeometry(scale: TimelineScale(framesPerPoint: 512), laneHeight: 40, range: .standard))
        #expect(geometry.lanesInView(top: 20, bottom: 200, count: 5) == 0..<5, "20 pt of the first lane")
        #expect(geometry.lanesInView(top: 21, bottom: 200, count: 5) == 1..<5, "19 pt of the first lane")
        #expect(geometry.lanesInView(top: 0, bottom: 180, count: 5) == 0..<5, "20 pt of the last lane")
        #expect(geometry.lanesInView(top: 0, bottom: 179, count: 5) == 0..<4, "19 pt of the last lane")
        #expect(geometry.lanesInView(top: 0, bottom: 400, count: 5) == 0..<5, "no lane after the last")
        #expect(geometry.lanesInView(top: 50, bottom: 70, count: 5) == 1..<2, "a view of 20 pt in lane 2")
        #expect(geometry.lanesInView(top: 50, bottom: 69, count: 5).isEmpty, "a view of 19 pt in lane 2")
        #expect(geometry.lanesInView(top: 70, bottom: 90, count: 5).isEmpty, "10 pt of lanes 2 and 3")
    }
}
