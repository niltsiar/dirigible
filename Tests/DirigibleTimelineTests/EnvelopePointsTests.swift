import DirigibleCore
import Testing

@testable import DirigibleTimeline

/// The points of a gain envelope that the lanes show and the hit test finds (decision 0060, run
/// 2026-10-18-envelope-ducking C9), on the small fixture: clip A at 48,000 ..< 96,000 of file fa
/// with offset 0, at 480 frames per point (x 100 to 200 pt), in lanes of 60 pt. The points are in
/// timeline frames: the frame 48,000 + f of A is the file frame f.
struct EnvelopePointsTests {
    /// The shown points of A after `edit` of a session whose A has `points` (timeline frame, dB).
    func shown(_ points: [Int: Double], edit: (inout Session) throws -> Void = { _ in }) throws
        -> [LaneGeometry.EnvelopePoint]
    {
        var session = try Fixture.session()
        try session.setEnvelope(
            Dictionary(uniqueKeysWithValues: points.map { (Frames($0.key), Gain(dB: $0.value)!) }), clip: "A")
        try edit(&session)
        let clips = session.tracks[0].clips
        return Fixture.geometry.envelopePoints(of: clips[0], at: 0, in: clips, trackGain: .zero, lane: 0)
    }

    @Test func aPointShowsAtItsFrameAndGainAndAHighPointStaysUnderTheTop() throws {
        let points = try shown([72_000: -6, 88_800: 6])

        #expect(points.map(\.index) == [0, 1])
        #expect(points.map(\.x) == [150, 185])
        // -6 dB is 6 pt under the lane top; +6 dB would be over it, and stays 3 pt under it.
        #expect(points.map(\.y) == [6, 3])
    }

    @Test func aPointOutsideTheClipWindowDoesNotShow() throws {
        let points = try shown([50_000: -6, 72_000: -6]) { try $0.trim("A", to: 60_000..<96_000) }

        #expect(points.map(\.index) == [1], "the point at the frame 50,000 is left of the new window")
    }

    @Test func twoPointsLessThanEightPointsApartHideEachOther() throws {
        #expect(try shown([62_400: -6, 66_000: -6]).isEmpty, "x 130 and x 137.5")
        #expect(try shown([62_400: -6, 66_240: -6]).map(\.x) == [130, 138], "8 pt apart is room enough")
    }

    @Test func aPointCloserThanEightPointsToAFadeHandleHides() throws {
        func faded(_ points: [Int: Double]) throws -> [LaneGeometry.EnvelopePoint] {
            try shown(points) { try $0.setFades(["A": Fades(fadeIn: 4_800, fadeOut: 0)!]) }
        }
        // The fade-in handle is 8 pt wide at the fade end, x 110 pt: its center is at x 110.
        #expect(try faded([55_680: -6]).isEmpty, "x 116 is 6 pt from the handle")
        #expect(try faded([57_120: -6]).map(\.x) == [119], "x 119 is 9 pt from the handle")
    }

    @Test func aBoxUnder40PointsShowsNoPoint() throws {
        #expect(try shown([56_000: -6]) { try $0.trim("A", to: 48_000..<64_800) }.isEmpty, "35 pt")
        #expect(try shown([56_000: -6]) { try $0.trim("A", to: 48_000..<78_000) }.count == 1, "62.5 pt")
    }

    /// Leveler C30: on a ridden clip, the gain line and the disc of a manual point follow the heard
    /// gain, the envelope plus the ride. The ride falls from 0 dB to -12 dB over the file frames of A.
    @Test func lineFollowsTheHeardGain() throws {
        var session = try Fixture.session()
        try session.setEnvelope([72_000: Gain(dB: -6)!], clip: "A")
        try session.setRides([
            "A": #require(
                GainEnvelope([
                    GainEnvelope.Point(frame: 0, gain: .zero), GainEnvelope.Point(frame: 48_000, gain: Gain(dB: -12)!),
                ]))
        ])
        let clips = session.tracks[0].clips
        let geometry = Fixture.geometry
        // The file frame 24,000 (x 150): the point -6 dB and the ride -6 dB.
        #expect(geometry.envelopePoints(of: clips[0], at: 0, in: clips, trackGain: .zero, lane: 0).map(\.y) == [12])
        #expect(abs(geometry.gainLineY(clips[0], trackGain: .zero, lane: 0, atX: 150) - 12) < 1e-9)
        // The file frame 12,000 (x 125): the envelope holds -6 dB, and the ride is -3 dB.
        #expect(abs(geometry.gainLineY(clips[0], trackGain: .zero, lane: 0, atX: 125) - 9) < 1e-9)
    }
}
