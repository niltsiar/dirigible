import DirigibleCore
import Testing

@testable import DirigibleTimeline

/// The waveform range in the geometry and the gestures: the gain line, the envelope points, and the
/// drags of gain scale with the range R, the dB under a lane height. The lanes are 100 pt high, at
/// 480 frames per point, so a drag of 10 pt is R / 10 dB. Clip A is x 100 to 200 pt on lane 0.
struct WaveformRangeTests {
    static let ranges = WaveformRange.allCases

    func geometry(_ range: WaveformRange) throws -> LaneGeometry {
        try #require(LaneGeometry(scale: TimelineScale(framesPerPoint: 480), laneHeight: 100, range: range))
    }

    func session(gain: Double = 0, points: [Int: Double] = [:]) throws -> Session {
        var session = try Fixture.session()
        try session.setGain(Gain(dB: gain)!, clip: "A")
        if !points.isEmpty {
            try session.setEnvelope(
                Dictionary(uniqueKeysWithValues: points.map { (Frames($0.key), Gain(dB: $0.value)!) }), clip: "A")
        }
        return session
    }

    @Test(arguments: [(WaveformRange.db24, 25.0), (.db36, 50.0 / 3), (.db48, 12.5), (.db60, 10), (.db96, 6.25)])
    func theGainLineFollowsTheRange(range: WaveformRange, y: Double) throws {
        let geometry = try geometry(range)
        let session = try session(gain: -6)
        let clip = session.tracks[0].clips[0]

        #expect(abs(geometry.gainLineY(clip, trackGain: .zero, lane: 0) - y) < 1e-9, "\(range.dB) dB")
        #expect(abs(geometry.gainLineY(clip, trackGain: .zero, lane: 1) - 100 - y) < 1e-9, "lane 1")
        #expect(abs(geometry.gainLineY(clip, trackGain: .zero, lane: 0, atX: 150) - y) < 1e-9, "at x")
        #expect(abs(range.fraction(dB: -6) - (1 - y / 100)) < 1e-9)
        if case .gain = geometry.hit(150, y, in: session) {} else { Issue.record("a press on the line must hit it") }
    }

    @Test func aPressAtTheLineOfAnotherRangeMissesTheGainBand() throws {
        let session = try session(gain: -6)

        if case .gain = try geometry(.db24).hit(150, 10, in: session) { Issue.record("10 pt is not the 24 dB line") }
        if case .gain = try geometry(.db60).hit(150, 10, in: session) {
        } else {
            Issue.record("10 pt is the 60 dB line")
        }
    }

    @Test func theFractionStaysInsideTheLane() {
        #expect(WaveformRange.db24.fraction(dB: 0) == 1)
        #expect(WaveformRange.db24.fraction(dB: -24) == 0)
        #expect(WaveformRange.db24.fraction(dB: -60) == 0, "under the range")
        #expect(WaveformRange.db24.fraction(dB: 6) == 1, "over 0 dBFS")
        #expect(WaveformRange.db60.fraction(dB: -6) == 0.9)
    }

    @Test func thePointsFollowTheRange() throws {
        let session = try session(points: [72_000: -12])
        let clips = session.tracks[0].clips
        for (range, y) in [(WaveformRange.db24, 50.0), (.db60, 20), (.db96, 12.5)] {
            let points = try geometry(range).envelopePoints(of: clips[0], at: 0, in: clips, trackGain: .zero, lane: 0)
            #expect(points.count == 1 && abs(points[0].y - y) < 1e-9, "\(range.dB) dB: \(points)")
        }
    }

    /// A drag of 10 pt up adds R / 10 dB, for the clip line, an envelope point, and a range gain.
    @Test(arguments: WaveformRangeTests.ranges)
    func aGainDragFollowsTheRange(range: WaveformRange) throws {
        let step = range.dB / 10
        let geometry = try geometry(range)
        func run(_ session: Session, press: (Double, Double), to y: Double, marks: Marks = Marks()) throws -> Session {
            var gesture = TimelineGesture()
            let context = GestureContext(
                session: session, selection: .range(marks), playhead: 1000, geometry: geometry, canEdit: true,
                canRipple: true, snaps: false)
            _ = gesture.handle(
                .down(.lanes(x: press.0, y: press.1), shift: false, command: false, option: false, clicks: 1), context)
            _ = gesture.handle(.drag(.lanes(x: press.0, y: y)), context)
            let effects = gesture.handle(.up(.lanes(x: press.0, y: y)), context)
            guard effects.count == 1, case .commit(let commit) = effects[0] else {
                throw Failure("no commit: \(effects)")
            }
            var result = session
            #expect(commit.apply(to: &result))
            return result
        }
        let tolerance = 0.05 + 1e-9

        let line = try run(session(gain: -12), press: (150, 1200 / range.dB), to: 1200 / range.dB - 10)
        #expect(abs(line.tracks[0].clips[0].gain.dB - (-12 + step)) <= tolerance, "clip line, \(range.dB) dB")

        let point = try run(session(points: [72_000: -8]), press: (150, 800 / range.dB), to: 800 / range.dB - 10)
        let moved = try #require(point.tracks[0].clips[0].envelope.points.first { $0.gain.dB != 0 })
        #expect(abs(moved.gain.dB - (-8 + step)) <= tolerance, "envelope point, \(range.dB) dB")

        let marks = Marks(inPoint: 62_400, outPoint: 81_600, tracks: ["t1"])
        let ranged = try run(session(), press: (150, 2), to: 12, marks: marks)
        #expect(abs(ranged.tracks[0].clips[0].envelope.gain(at: 20_000) + step) <= tolerance, "range gain")
    }

    @Test func aStoredRangeIsValidated() {
        #expect(WaveformRange(stored: 96) == .db96)
        #expect(WaveformRange(stored: 24) == .db24)
        #expect(WaveformRange(stored: 50) == .db60, "not a range")
        #expect(WaveformRange(stored: "x") == .db60, "not a number")
        #expect(WaveformRange(stored: 120) == .db60, "no range of 120 dB yet")
        #expect(WaveformRange(stored: -60) == .db60)
        #expect(WaveformRange(stored: nil) == .db60, "no stored value")
    }

    @Test func theStepsRunUpAndDownTheRanges() {
        #expect(WaveformRange.standard == .db60)
        #expect(WaveformRange.db60.zoomedIn == .db72 && WaveformRange.db84.zoomedIn == .db96)
        #expect(WaveformRange.db96.zoomedIn == nil)
        #expect(WaveformRange.db60.zoomedOut == .db48 && WaveformRange.db36.zoomedOut == .db24)
        #expect(WaveformRange.db24.zoomedOut == nil)
    }
}

private struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
