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
        #expect(WaveformRange.standard.fraction(dB: -6) == 0.9)
    }

    /// Code gate nit: the line of the hit test and the row of the renderer use one scale.
    @Test func theTwoGainLineFormulasAgree() {
        for dB in [-70, -60, -45.5, -20, -6, -0.1, 0, 4] {
            var a = Fixture.a
            a.gain = Gain(dB: dB)!
            let y = geometry.gainLineY(a, trackGain: .zero, lane: 0)
            #expect(abs(y - 60 * (1 - WaveformRange.standard.fraction(dB: dB))) < 1e-9, "\(dB) dB")
        }
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

    /// G0 (run 11c-2): a crossfade of 19,200 frames (20 pt on each side of J at x 200) has a handle
    /// at J - L/2 in A and at J + L/2 in B, each inside its box. With no crossfade, the joined
    /// edges have none.
    @Test func aCrossfadeHasAHandleAtEachHalf() throws {
        var session = try Fixture.session()
        try session.move("B", to: "t1", start: 96_000)
        try session.setCrossfades(["A": 19_200])
        let lane = session.tracks[0].clips

        #expect(
            geometry.fadeHandles(of: lane[0], at: 0, in: lane, lane: 0).end == Rect(x: 176, y: 0, width: 8, height: 8))
        #expect(
            geometry.fadeHandles(of: lane[1], at: 1, in: lane, lane: 0).start == Rect(x: 216, y: 0, width: 8, height: 8)
        )
        #expect(LaneGeometry.hasHandle(fade: .zero, crossfade: 960, joined: true))
        #expect(!LaneGeometry.hasHandle(fade: .zero, crossfade: .zero, joined: true))
        try session.setCrossfades(["A": 0])
        let plain = session.tracks[0].clips
        #expect(geometry.fadeHandles(of: plain[0], at: 0, in: plain, lane: 0).end == nil)
        #expect(geometry.fadeHandles(of: plain[1], at: 1, in: plain, lane: 0).start == nil)
    }

    /// G8 (run 11c-2): at L/2 under 4 pt (960 frames, 1 pt) the two handles meet at J (x 200) and
    /// cover the top 8 pt of both trim zones; under them the trim stays.
    @Test func aCrossfadeHandleCoversTheTopOfTheTrim() throws {
        var session = try Fixture.session()
        try session.move("B", to: "t1", start: 96_000)
        try session.setCrossfades(["A": 960])
        let (a, b) = (session.clip("A")!.clip, session.clip("B")!.clip)

        #expect(geometry.hit(198, 2, in: session) == .fade(a, .end, lane: 0))
        #expect(geometry.hit(202, 2, in: session) == .fade(b, .start, lane: 0))
        #expect(geometry.hit(198, 20, in: session) == .trim(a, .end, lane: 0))
        #expect(geometry.hit(202, 20, in: session) == .trim(b, .start, lane: 0))
    }

    /// G11 (run 11c-2): the gain band of A at -20 dB (y 20) stops at the crossfade half (x 180).
    /// Fail value: the band up to the join.
    @Test func theGainBandStopsAtTheCrossfade() throws {
        var session = try Fixture.session()
        try session.move("B", to: "t1", start: 96_000)
        try session.setGain(Gain(dB: -20)!, clip: "A")
        try session.setCrossfades(["A": 19_200])
        let a = session.clip("A")!.clip

        #expect(geometry.hit(170, 20, in: session) == .gain(a, lane: 0))
        #expect(geometry.hit(185, 20, in: session) == .move(a, lane: 0))
    }

    /// Code gate K1: fades that fill the clip leave no gain band (the hit is a handle or a move). At 50 frames per point and this start,
    /// the fade-in end x is 1 ulp over the fade-out start x, and a range from the two trapped.
    @Test func fadesThatFillTheClipLeaveNoBand() throws {
        let geometry = try #require(
            LaneGeometry(scale: TimelineScale(framesPerPoint: 50), laneHeight: 60, range: .standard))
        var session = try Fixture.session(withB: false)
        try session.addFile(AudioFile(id: "fl", path: "fl.wav", layout: .mono, length: 60_000_000))
        let clip = Clip(id: "L", file: "fl", start: 52_395_616, offset: 0, length: 48_000)
        try session.place(clip, on: "t2")
        try session.setFades(["L": Fades(fadeIn: 24_000, fadeOut: 24_000)!])
        let box = geometry.box(of: clip, lane: 1)

        for x in stride(from: box.minX + 10, to: box.maxX - 10, by: 0.25) {
            #expect(geometry.hit(x, 63, in: session) != .gain(session.clip("L")!.clip, lane: 1), "x \(x)")
        }
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
