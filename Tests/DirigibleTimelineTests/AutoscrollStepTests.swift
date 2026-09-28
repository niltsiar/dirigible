import Testing

@testable import DirigibleTimeline

/// Timeline-navigation criterion N16 (U16): the autoscroll points of one tick. The lanes in view
/// are 1000 pt wide; a tick is 0.1 s, so 20 pt/s per pt outside is 2 pt per pt.
struct AutoscrollStepTests {
    static func step(_ x: Double, screen: (Bool, Bool) = (false, false), seconds: Double = 0) -> Double {
        autoscrollStep(x: x, width: 1000, edgesAtScreen: screen, secondsInZone: seconds, tick: 0.1)
    }

    @Test func insideTheLanesNothingScrolls() {
        #expect(Self.step(0) == 0)
        #expect(Self.step(500) == 0)
        #expect(Self.step(1000) == 0)
    }

    @Test func outsideTheSpeedGrowsWithTheDistance() {
        #expect(Self.step(1010) == 20, "10 pt right: 200 pt/s")
        #expect(Self.step(1040) == 80)
        #expect(Self.step(-10) == -20, "left of the lanes scrolls left")
    }

    /// The ramp min(4, 1 + seconds in the zone).
    @Test func theSpeedRampsInTheZone() {
        #expect(Self.step(1010, seconds: 0) == 20)
        #expect(Self.step(1010, seconds: 1) == 40, "the speed doubles after 1 s")
        #expect(Self.step(1010, seconds: 3) == 80)
        #expect(Self.step(1010, seconds: 5) == 80, "the ramp stops at 4")
    }

    @Test func theSpeedStopsAt3000PointsPerSecond() {
        #expect(Self.step(1500, seconds: 5) == 300, "the speed stops at 3000 pt/s")
        #expect(Self.step(-1500, seconds: 5) == -300, "the speed stops at 3000 pt/s")
    }

    /// The 16 pt inner zone of an edge counts only when that edge touches the screen edge.
    @Test func theInnerZoneNeedsTheScreenEdge() {
        #expect(Self.step(992) == 0, "8 pt inside scrolls only at the screen edge")
        #expect(Self.step(992, screen: (false, true)) == 16, "8 pt inside scrolls only at the screen edge")
        #expect(Self.step(8, screen: (true, false)) == -16)
        #expect(Self.step(8, screen: (false, true)) == 0)
        #expect(Self.step(980, screen: (false, true)) == 0, "20 pt inside does not scroll")
    }
}
