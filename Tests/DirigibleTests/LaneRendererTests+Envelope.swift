import CoreGraphics
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The gain envelope on the lanes (decision 0060, run 2026-10-18-envelope-ducking C9). A clip of
/// 400 pt (102,400 frames at 256 frames per point), scale 1, lanes of 100 px.
extension LaneRendererTests {
    static let envelopeLength = 102_400

    /// The lanes with the clip `c1` on `t1` and the envelope `points` of (file frame, dB).
    static func envelopeSession(_ points: [(Int, Double)]) throws -> Session {
        var session = try Self.session(length: envelopeLength)
        let envelope = try #require(
            GainEnvelope(points.map { GainEnvelope.Point(frame: Frames($0.0), gain: Gain(dB: $0.1)!) }))
        try session.setEnvelopes(["c1": envelope])
        return session
    }

    static func fullPeaks() -> [PeakColumn] { Array(repeating: PeakColumn(peak: 65535, rms: 0), count: 400) }

    /// The rows of `column` in lane 0 that hold the waveform or the gain line.
    static func drawn(_ pixels: OwnedPixels, column: Int) -> Int {
        (0..<100).filter { [LanePalette.light.peak, LanePalette.light.label].contains(pixels.pixel(column, $0)) }.count
    }

    /// A ramp from 0 dB to -16 dB over 100 pt, a plateau of 200 pt, and a ramp back. Each column draws
    /// the dB height of the highest envelope gain over its frames: the ramp down at its first frame
    /// (a closed form of the points), the plateau at -16 dB. A 0 dBFS column of the same peak with no
    /// envelope is the control: 100 rows.
    @Test func aDuckedColumnDrawsLower() throws {
        let session = try Self.envelopeSession([(0, 0), (25_600, -16), (76_800, -16), (102_400, 0)])
        let pixels = try Self.render(Self.inputs(session, peaks: Self.fullPeaks()), width: 400)
        let palette = LanePalette.light

        let plateau = Self.drawn(pixels, column: 150)
        #expect(abs(plateau - Self.height(dB: -16)) <= 1, "plateau column: \(plateau) rows")
        let misses = (10..<90).filter { column in
            abs(Self.drawn(pixels, column: column) - Self.height(dB: -16 * Double(column * 256) / 25_600)) > 1
        }
        #expect(misses.isEmpty, "ramp columns off the dB map of the envelope: \(misses)")
        // The line of the plateau column is one row at the top of the waveform.
        #expect(Self.rows(pixels, column: 150, palette.label) == [100 - Self.height(dB: -16)])
        let plain = try Self.render(
            Self.inputs(Self.session(length: Self.envelopeLength), peaks: Self.fullPeaks()), width: 400)
        #expect(Self.drawn(plain, column: 150) == 100, "the control column has no envelope")
    }

    /// The line of an envelope clip stays 3 pt under the clip top, where the envelope is 0 dB. The
    /// control: a clip with no envelope keeps its line on the top row.
    @Test func anEnvelopeLineStaysThreePointsUnderTheClipTop() throws {
        let session = try Self.envelopeSession([(0, 0), (Self.envelopeLength, 0)])
        let pixels = try Self.render(Self.inputs(session, peaks: Self.fullPeaks()), width: 400)
        #expect(Self.rows(pixels, column: 200, LanePalette.light.label) == [3])

        let plain = try Self.render(
            Self.inputs(Self.session(length: Self.envelopeLength), peaks: Self.fullPeaks()), width: 400)
        #expect(Self.rows(plain, column: 200, LanePalette.light.label) == [0])
    }

    /// Points 4 pt apart draw no disc: each column has the one row of the line. The control: points
    /// 100 pt apart draw a disc of 6 pt at each point, and a column far from a point has the line only.
    @Test func densePointsDrawOnlyTheLine() throws {
        let label = LanePalette.light.label
        let line = 100 - Self.height(dB: -16)
        let dense = try Self.envelopeSession((25..<99).map { ($0 * 1024, -16) })
        let densePixels = try Self.render(Self.inputs(dense, peaks: Self.fullPeaks()), width: 400)
        for column in [150, 252, 256, 257] {
            #expect(Self.rows(densePixels, column: column, label) == [line], "dense column \(column)")
        }

        let sparse = try Self.envelopeSession([(25_600, -16), (51_200, -16), (76_800, -16)])
        let sparsePixels = try Self.render(Self.inputs(sparse, peaks: Self.fullPeaks()), width: 400)
        #expect(Self.rows(sparsePixels, column: 150, label) == [line], "between two points")
        let atPoint = Self.rows(sparsePixels, column: 100, label)
        #expect(atPoint == Array((line - 3)..<(line + 3)), "a disc of 6 px around the line row: \(atPoint)")
    }
}
