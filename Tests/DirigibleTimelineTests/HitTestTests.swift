import DirigibleCore
import Testing

@testable import DirigibleTimeline

/// Mouse-edits criteria 1 and 14: the zones of a lane point on the small fixture (A is x 100 to
/// 200 pt on lane 0, y 0 to 60 pt).
struct HitTestTests {
    let geometry = Fixture.geometry

    @Test func fourPointsInsideAnEdgeIsTheTrimZone() throws {
        let session = try Fixture.session()

        #expect(geometry.hit(103.9, 10, in: session) == .trim(Fixture.a, .start, lane: 0))
        #expect(geometry.hit(103.9, 55, in: session) == .trim(Fixture.a, .start, lane: 0), "at full height")
        #expect(geometry.hit(196.1, 10, in: session) == .trim(Fixture.a, .end, lane: 0))
        #expect(geometry.hit(104.1, 10, in: session) == .move(Fixture.a, lane: 0))
        #expect(geometry.hit(195.9, 10, in: session) == .move(Fixture.a, lane: 0))
    }

    @Test func theUpperTwoThirdsOfAClipIsTheMoveZone() throws {
        let session = try Fixture.session()

        #expect(geometry.hit(104.1, 10, in: session) == .move(Fixture.a, lane: 0))
        #expect(geometry.hit(150, 30, in: session) == .move(Fixture.a, lane: 0))
        #expect(geometry.hit(150, 39.9, in: session) == .move(Fixture.a, lane: 0))
        #expect(geometry.hit(150, 70, in: session) == .move(Fixture.c, lane: 1))
    }

    @Test func theLowerThirdAGapAndAnEmptyLaneAreTheRangeZone() throws {
        let session = try Fixture.session()

        #expect(geometry.hit(104.1, 45, in: session) == .range(lane: 0))
        #expect(geometry.hit(150, 59.9, in: session) == .range(lane: 0), "the lower edge of lane 0")
        #expect(geometry.hit(99, 10, in: session) == .range(lane: 0), "the gap before A")
        #expect(geometry.hit(150, 130, in: session) == .range(lane: 2), "t3 has no clip")
        #expect(geometry.hit(150, 180, in: session) == .range(lane: nil), "under the last lane")
    }

    /// A box under 12 pt has no trim zone and no move zone (plan gate 1 item 1). D is 11.9 pt
    /// wide from x 900, E is 12 pt wide from x 1000.
    @Test func aBoxUnderTwelvePointsIsAllRange() throws {
        var session = try Fixture.session()
        let d = Clip(id: "D", file: "fa", start: 432_000, offset: 0, length: 5712)
        let e = Clip(id: "E", file: "fa", start: 480_000, offset: 0, length: 5760)
        try session.place(d, on: "t1")
        try session.place(e, on: "t1")

        #expect(geometry.hit(905.95, 10, in: session) == .range(lane: 0))
        #expect(geometry.hit(1006, 10, in: session) == .move(e, lane: 0))
    }

    @Test func eachZoneHasItsCursor() {
        #expect(LaneHit.move(Fixture.a, lane: 0).cursor == .arrow)
        #expect(LaneHit.trim(Fixture.a, .start, lane: 0).cursor == .resizeLeftRight)
        #expect(LaneHit.trim(Fixture.a, .end, lane: 0).cursor == .resizeLeftRight)
        #expect(LaneHit.gain(Fixture.a, lane: 0).cursor == .resizeUpDown)
        #expect(LaneHit.fade(Fixture.a, .start, lane: 0).cursor == .resizeLeftRight)
        #expect(LaneHit.fade(Fixture.a, .end, lane: 0).cursor == .resizeLeftRight)
        #expect(LaneHit.range(lane: 0).cursor == .iBeam)
        #expect(LaneHit.range(lane: nil).cursor == .iBeam)
        #expect(RulerHit.flag("m1").cursor == .resizeLeftRight)
        #expect(RulerHit.triangle(.inPoint).cursor == .resizeLeftRight)
        #expect(RulerHit.triangle(.outPoint).cursor == .resizeLeftRight)
        #expect(RulerHit.time(0).cursor == .arrow)
    }

    /// A clip D of 40 pt (x 400 to 440, 480 frames per point) touches the end of B, so its start edge
    /// has no fade handle; its end edge has one at x 432 to 440, y 0 to 8. The envelope has three
    /// points: x 401 and x 415 at -20 dB (y 20), and x 428 at 0 dB (y 3, 3 pt under the box top).
    func sessionWithFortyPointClip() throws -> (Session, Clip) {
        var session = try Fixture.session()
        try session.place(Clip(id: "D", file: "fb", start: 192_000, offset: 0, length: 19_200), on: "t1")
        try session.setEnvelope([192_480: Gain(dB: -20)!, 199_200: Gain(dB: -20)!, 205_440: .zero], clip: "D")
        return (session, try #require(session.clip("D")?.clip))
    }

    /// Hit order (plan gate U15): a fade handle, then a point, then the trim zones, then the gain
    /// line. Each test presses where two zones overlap, and a control where only the lower one is.
    @Test func aFadeHandleIsHitBeforeAPoint() throws {
        let (session, d) = try sessionWithFortyPointClip()

        #expect(
            geometry.hit(432.5, 4, in: session) == .fade(d, .end, lane: 0), "in the handle and 4.6 pt from the point")
        #expect(geometry.hit(427, 4, in: session) == .point(d, index: 2, lane: 0), "in the zone of the point only")
    }

    @Test func aPointIsHitBeforeATrimZoneAndTheGainLine() throws {
        let (session, d) = try sessionWithFortyPointClip()

        #expect(geometry.hit(401, 20, in: session) == .point(d, index: 0, lane: 0), "1 pt inside the start edge")
        #expect(geometry.hit(402.5, 20, in: session) == .point(d, index: 0, lane: 0), "on the line, at the point")
        #expect(geometry.hit(409, 20, in: session) == .gain(d, lane: 0), "on the line, 6 pt from the point")
        #expect(geometry.hit(403, 10, in: session) == .trim(d, .start, lane: 0), "off the line, in the trim zone")
    }

    @Test func aHiddenPointIsNotHit() throws {
        var (session, d) = try sessionWithFortyPointClip()
        try session.setEnvelope([192_480: Gain(dB: -20)!, 195_840: Gain(dB: -20)!], clip: "D")
        d = try #require(session.clip("D")?.clip)

        // The points are 7 pt apart, so neither shows.
        #expect(geometry.hit(408, 20, in: session) == .gain(d, lane: 0))
        #expect(geometry.hit(401, 20, in: session) == .trim(d, .start, lane: 0))
    }
}
