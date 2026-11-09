import DirigibleCore
import Testing

@testable import DirigibleTimeline

/// The mouse actions on the gain envelope (decision 0060, run 2026-10-18-envelope-ducking C10), on
/// the small fixture: 480 frames per point, 60 pt lanes, so 1 dB per pt; clip A is x 100 to 200 pt
/// on lane 0, file offset 0, so the file frame f of A is the timeline frame 48,000 + f.
/// A has the points x 125 (0 dB), x 150 (-8 dB), and x 175 (0 dB), as timeline frames 60,000,
/// 72,000, and 84,000. Its gain band is y 0 to 6 at 0 dB; the line at x 150 is at y 8.
struct EnvelopeGestureTests {
    var session: Session
    var gesture = TimelineGesture()

    init() throws {
        session = try Fixture.session()
        try setPoints([60_000: 0, 72_000: -8, 84_000: 0])
    }

    mutating func setPoints(_ points: [Int: Double]) throws {
        try session.setEnvelope(
            Dictionary(uniqueKeysWithValues: points.map { (Frames($0.key), Gain(dB: $0.value)!) }), clip: "A")
    }

    func context(marks: Marks = Marks()) -> GestureContext {
        GestureContext(
            session: session, selection: .range(marks), playhead: 1000, geometry: Fixture.geometry, canEdit: true,
            canRipple: true, snaps: false)
    }

    mutating func down(
        _ x: Double, _ y: Double, clicks: Int = 1, option: Bool = false, marks: Marks = Marks()
    ) {
        let effects = gesture.handle(
            .down(.lanes(x: x, y: y), shift: false, command: false, option: option, clicks: clicks),
            context(marks: marks))
        precondition(effects.isEmpty)
    }

    mutating func drag(_ x: Double, _ y: Double) -> [GestureEffect] {
        gesture.handle(.drag(.lanes(x: x, y: y)), context())
    }

    mutating func up(_ x: Double, _ y: Double) -> [GestureEffect] {
        gesture.handle(.up(.lanes(x: x, y: y)), context())
    }

    func drawnA() -> Clip { gesture.drawn(session).clip("A")!.clip }

    /// The session after the one commit of `effects`, or nil when there is none.
    func committed(_ effects: [GestureEffect]) -> Session? {
        guard effects.count == 1, case .commit(let commit) = effects[0] else { return nil }
        var result = session
        return commit.apply(to: &result) ? result : nil
    }

    /// The points of A as (file frame, dB).
    func points(_ session: Session) -> [(Int, Double)] {
        session.clip("A")!.clip.envelope.points.map { ($0.frame.count, $0.gain.dB) }
    }

    func expectPoints(_ session: Session, _ expected: [(Int, Double)], _ note: Comment? = nil) {
        let actual = points(session)
        #expect(actual.count == expected.count && zip(actual, expected).allSatisfy { $0 == $1 }, note ?? "\(actual)")
    }

    @Test mutating func aDragOfTheLineInARangeInsideTheClipIsARangeGainWithHalfSecondRamps() throws {
        try setPoints([:])
        let marks = Marks(inPoint: 62_400, outPoint: 81_600, tracks: ["t1"])
        down(150, 2, marks: marks)
        #expect(drag(150, 8) == [])
        let effects = up(150, 8)

        let result = try #require(committed(effects))
        let envelope = try #require(result.clip("A")?.clip.envelope)
        // The range is the file frames 14,400 ..< 33,600: -6 dB inside, and 24,000-frame ramps.
        #expect(envelope.gain(at: 20_000) == -6)
        #expect(abs(envelope.gain(at: 0) + 2.4) < 1e-9, "the ramp starts at the file frame -9,600")
        #expect(abs(envelope.gain(at: 45_599) + 3) < 1e-9, "the middle of the ramp after the range")
        #expect(envelope.gain(at: 57_599) == 0)
        #expect(result.clip("A")?.clip.gain == .zero, "the clip gain stays")
        #expect(result.clip("C")?.clip.envelope.isEmpty == true, "t2 is not in the range")
        if case .commit(let commit) = effects[0] { #expect(commit.selection == nil, "the range stays") }
    }

    @Test mutating func aDragOfTheLineOutsideTheRangeOrOfAWholeClipRangeIsAClipGainDrag() throws {
        let inside = Marks(inPoint: 62_400, outPoint: 81_600, tracks: ["t1"])
        down(190, 2, marks: inside)
        _ = drag(190, 8)
        #expect(drawnA().gain == Gain(dB: -6), "the press is right of the range")
        #expect(drawnA().envelope == session.clip("A")?.clip.envelope)
        _ = gesture.handle(.escape, context())
        _ = up(190, 8)

        // At x 140 the line is at y 4.8.
        down(140, 4.8, marks: Marks(inPoint: 48_000, outPoint: 96_000, tracks: ["t1"]))
        _ = drag(140, 10.8)
        #expect(drawnA().gain == Gain(dB: -6), "a range of the whole clip is a clip selection")
    }

    @Test mutating func anOptionClickOnTheLineAddsAPointThatChangesNoSample() throws {
        // The line at x 140 (timeline frame 67,200) is -4.8 dB.
        down(140, 4.8, option: true)
        let effects = up(140, 4.8)

        let result = try #require(committed(effects))
        let new = try #require(result.clip("A")?.clip.envelope)
        let old = try #require(session.clip("A")?.clip.envelope)
        #expect(new.points.count == 4)
        #expect(new.points.map(\.frame.count) == [12_000, 19_200, 24_000, 36_000])
        #expect(abs(new.points[1].gain.dB + 4.8) < 1e-9)
        let frames = [0, 12_000, 15_000, 19_200, 22_000, 24_000, 30_000, 36_000, 50_000]
        #expect(
            frames.allSatisfy { abs(new.gain(at: Frames($0)) - old.gain(at: Frames($0))) < 1e-9 }, "no sample changes")
    }

    /// The mouse and the keyboard add the same point: Option-K at the timeline frame of an
    /// Option-click gives the envelope that the click gives.
    @Test mutating func anOptionClickAndOptionKGiveTheSameEnvelope() throws {
        down(140, 4.8, option: true)
        let clicked = try #require(committed(up(140, 4.8))?.clip("A")?.clip.envelope)

        let keyed = try #require(PointGain.envelopes(nil, at: 67_200, for: ["A"], in: session)?["A"])

        #expect(clicked == keyed, "\(clicked.points) and \(keyed.points)")
    }

    @Test mutating func aPointDragMovesInTimeAndDecibelsAndStopsAtItsNeighbors() throws {
        down(150, 8)
        #expect(gesture.readout == nil, "no drag yet")
        #expect(drag(160, 14) == [])
        #expect(gesture.readout == .point(Gain(dB: -14)!))
        expectPoints(gesture.drawn(session), [(12_000, 0), (28_800, -14), (36_000, 0)], "the preview")
        let moved = try #require(committed(up(160, 14)))
        expectPoints(moved, [(12_000, 0), (28_800, -14), (36_000, 0)])

        down(150, 8)
        _ = drag(400, 8)
        expectPoints(gesture.drawn(session), [(12_000, 0), (35_999, -8), (36_000, 0)])
        _ = drag(10, 8)
        expectPoints(gesture.drawn(session), [(12_000, 0), (12_001, -8), (36_000, 0)])
        _ = drag(150, 100)
        #expect(gesture.readout == .point(Gain(dB: -60)!), "the lane floor")
        _ = drag(150, -100)
        #expect(gesture.readout == .point(Gain(dB: Gain.levelLimit)!), "the level limit")
    }

    @Test mutating func aPointStaysInsideTheClipWindow() throws {
        try setPoints([72_000: -8])
        down(150, 8)
        _ = drag(400, 8)
        expectPoints(gesture.drawn(session), [(47_999, -8)])
        _ = drag(10, 8)
        expectPoints(gesture.drawn(session), [(0, -8)])
    }

    @Test mutating func anOptionDragAddsAPointAndMovesIt() throws {
        down(140, 4.8, option: true)
        _ = drag(140, 10)
        #expect(gesture.readout == .point(Gain(dB: -10)!))
        let result = try #require(committed(up(140, 10)))
        expectPoints(result, [(12_000, 0), (19_200, -10), (24_000, -8), (36_000, 0)])
    }

    @Test mutating func aDoubleClickOnAPointRemovesIt() throws {
        down(150, 8, clicks: 2)
        let result = try #require(committed(up(150, 8)))

        expectPoints(result, [(12_000, 0), (36_000, 0)])
    }

    @Test mutating func aDoubleClickOnTheLineSetsTheGainAndKeepsThePoints() throws {
        try session.setGain(Gain(dB: -6)!, clip: "A")
        // At x 140 the envelope is -4.8 dB: with the clip gain, the line is at y 10.8.
        down(140, 10.8, clicks: 2)
        let result = try #require(committed(up(140, 10.8)))

        #expect(result.clip("A")?.clip.gain == .zero)
        #expect(result.clip("A")?.clip.envelope == session.clip("A")?.clip.envelope, "the points stay")
    }

    @Test mutating func aDragOnALowLineIsAGainDrag() throws {
        try session.setGain(Gain(dB: -20)!, clip: "A")
        try setPoints([60_000: -20, 84_000: -20])
        // The line at x 140 is at -40 dB: y 40, where the lower third (a range) starts.
        down(140, 42)
        _ = drag(140, 36)

        #expect(drawnA().gain == Gain(dB: -14), "a clip gain drag, not a range")
        #expect(drawnA().envelope == session.clip("A")?.clip.envelope)
    }

    /// The disc of a manual point on a ridden clip sits on the heard line, a drag of it
    /// moves the manual point by the drag delta, and the ride stays equal.
    @Test mutating func dragOnARiddenClipKeepsTheRide() throws {
        let ride = try #require(
            GainEnvelope([
                GainEnvelope.Point(frame: 0, gain: Gain(dB: -6)!),
                GainEnvelope.Point(frame: 48_000, gain: Gain(dB: -6)!),
            ]))
        try session.setRides(["A": ride])
        // At x 150 the heard gain is -8 dB plus -6 dB: the disc is at y 14.
        down(150, 14)
        _ = drag(150, 17)
        #expect(gesture.readout == .point(Gain(dB: -11)!))
        let moved = try #require(committed(up(150, 17)))
        expectPoints(moved, [(12_000, 0), (24_000, -11), (36_000, 0)])
        #expect(moved.clip("A")?.clip.ride == ride, "the drag leaves the ride equal")
    }
}
