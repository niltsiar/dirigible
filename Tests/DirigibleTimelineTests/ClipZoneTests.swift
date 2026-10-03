import DirigibleCore
import Testing

@testable import DirigibleTimeline

/// Criteria Z1 to Z6 and Z8 of run 11b-1: the gain line, the fade handles, and the zones of a clip
/// box on the small fixture (480 frames per point, 60 pt lanes, so 1 dB per pt; A is x 100 to
/// 200 pt on lane 0).
struct ClipZoneTests {
    let geometry = Fixture.geometry

    /// The session with clip A changed by `change`.
    func session(_ change: (inout Clip) -> Void) throws -> Session {
        var session = try Fixture.session()
        var a = Fixture.a
        change(&a)
        try session.setGain(a.gain, clip: "A")
        try session.setFades(["A": a.fades])
        return session
    }

    func a(_ session: Session) -> Clip { session.clip("A")!.clip }

    @Test func theGainLineFollowsTheWaveformScale() {
        func y(_ clip: Double, track: Double = 0) -> Double {
            var a = Fixture.a
            a.gain = Gain(dB: clip)!
            return geometry.gainLineY(a, trackGain: Gain(dB: track)!, lane: 0)
        }

        #expect(abs(y(0)) < 1e-9)
        #expect(abs(y(-6) - 6) < 1e-9)
        #expect(abs(y(-6, track: -3) - 9) < 1e-9, "the track gain adds")
        #expect(abs(y(4)) < 1e-9, "over 0 dB the line stays at the top")
        #expect(abs(y(-60) - 60) < 1e-9)
        #expect(abs(y(-70) - 60) < 1e-9)
        var c = Fixture.c
        c.gain = Gain(dB: -6)!
        #expect(abs(geometry.gainLineY(c, trackGain: .zero, lane: 1) - 66) < 1e-9, "lane 1")
        #expect(LaneGeometry.gainFraction(dB: -6) == 0.9)
    }

    @Test func theHandlesSitAtTheFadeEnds() throws {
        func handles(_ fadeIn: Int, _ fadeOut: Int) throws -> (start: Rect?, end: Rect?) {
            let session = try session { $0.fades = Fades(fadeIn: Frames(fadeIn), fadeOut: Frames(fadeOut))! }
            return geometry.fadeHandles(of: a(session), at: 0, in: session.tracks[0].clips, lane: 0)
        }
        func rect(_ x: Double) -> Rect { Rect(x: x, y: 0, width: 8, height: 8) }

        let none = try handles(0, 0)
        #expect(none.start == rect(100))
        #expect(none.end == rect(192))
        #expect(try handles(4_800, 0).start == rect(106), "10 pt of fade")
        #expect(try handles(47_520, 0).start == rect(192), "clamped inside the box")

        let overlap = try session { $0.fades = Fades(fadeIn: 21_120, fadeOut: 24_000)! }
        #expect(geometry.hit(146.5, 2, in: overlap) == .fade(a(overlap), .start, lane: 0), "left half of the overlap")
        #expect(geometry.hit(147.5, 2, in: overlap) == .fade(a(overlap), .end, lane: 0), "right half of the overlap")
        let full = try session { $0.fades = Fades(fadeIn: 47_520, fadeOut: 0)! }
        #expect(geometry.hit(195, 2, in: full) == .fade(a(full), .start, lane: 0))
        #expect(geometry.hit(197, 2, in: full) == .fade(a(full), .end, lane: 0))
    }

    @Test func theZonesInHitOrder() throws {
        let session = try Fixture.session()
        let a = Fixture.a

        #expect(geometry.hit(101, 2, in: session) == .fade(a, .start, lane: 0))
        #expect(geometry.hit(199, 2, in: session) == .fade(a, .end, lane: 0))
        #expect(geometry.hit(101, 20, in: session) == .trim(a, .start, lane: 0))
        #expect(geometry.hit(150, 2, in: session) == .gain(a, lane: 0))
        #expect(geometry.hit(150, 5, in: session) == .gain(a, lane: 0))
        #expect(geometry.hit(150, 7, in: session) == .move(a, lane: 0))
        #expect(geometry.hit(150, 45, in: session) == .range(lane: 0))
    }

    @Test func theGainBandIsThreePointsAroundTheLine() throws {
        let quiet = try session { $0.gain = Gain(dB: -20)! }
        let clip = a(quiet)

        #expect(geometry.hit(150, 17, in: quiet) == .gain(clip, lane: 0))
        #expect(geometry.hit(150, 23, in: quiet) == .gain(clip, lane: 0))
        #expect(geometry.hit(150, 16, in: quiet) == .move(clip, lane: 0))
        #expect(geometry.hit(150, 24, in: quiet) == .move(clip, lane: 0))
        let faded = try session {
            $0.gain = Gain(dB: -20)!
            $0.fades = Fades(fadeIn: 4_800, fadeOut: 4_800)!
        }
        #expect(geometry.hit(108, 20, in: faded) == .move(a(faded), lane: 0), "in the fade-in")
        #expect(geometry.hit(192, 20, in: faded) == .move(a(faded), lane: 0), "in the fade-out")
        #expect(geometry.hit(150, 20, in: faded) == .gain(a(faded), lane: 0), "between the fades")
    }

    /// D is 40, 39, or 11 pt wide from x 500 on t1.
    @Test func handlesAndBandOnlyInBoxesOf40Points() throws {
        func hits(_ length: Frames) throws -> (corner: LaneHit, middle: LaneHit, d: Clip) {
            var session = try Fixture.session()
            let d = Clip(id: "D", file: "fa", start: 240_000, offset: 0, length: length)
            try session.place(d, on: "t1")
            return (geometry.hit(501, 2, in: session), geometry.hit(520, 2, in: session), d)
        }

        let wide = try hits(19_200)
        #expect(wide.corner == .fade(wide.d, .start, lane: 0), "40 pt")
        #expect(wide.middle == .gain(wide.d, lane: 0), "40 pt")
        let narrow = try hits(18_720)
        #expect(narrow.corner == .trim(narrow.d, .start, lane: 0), "39 pt")
        #expect(narrow.middle == .move(narrow.d, lane: 0), "39 pt")
        #expect(try hits(5_280).corner == .range(lane: 0), "11 pt")
    }

    @Test func noHandleAtAButtJoinWithNoFade() throws {
        var session = try Fixture.session()
        try session.move("B", to: "t1", start: 96_000)
        let b = session.clip("B")!.clip

        #expect(geometry.hit(199, 2, in: session) == .trim(Fixture.a, .end, lane: 0))
        #expect(geometry.hit(201, 2, in: session) == .trim(b, .start, lane: 0))
        #expect(geometry.hit(101, 2, in: session) == .fade(Fixture.a, .start, lane: 0), "the free edge keeps it")
        try session.setFades(["A": Fades(fadeIn: 0, fadeOut: 480)!])
        #expect(geometry.hit(199, 2, in: session) == .fade(session.clip("A")!.clip, .end, lane: 0))
    }

    @Test func joinsFindTheTouchingNeighbors() throws {
        var session = try Fixture.session(withB: false)
        try session.place(Clip(id: "B", file: "fb", start: 96_000, offset: 48_000, length: 48_000), on: "t1")
        let lane = session.tracks[0].clips

        #expect(lane.joins(at: 0) == (before: false, after: true))
        #expect(lane.joins(at: 1) == (before: true, after: false))
        try session.move("B", to: "t1", start: 96_001)
        #expect(session.tracks[0].clips.joins(at: 0) == (before: false, after: false))
        #expect(session.tracks[0].clips.joins(at: 1) == (before: false, after: false))
    }
}
