import CoreGraphics
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The waveform range on the lane pixels: the column heights, the fade lines, the gain line, and the
/// live take at each range. 100 pt lanes, 256 frames per point.
extension LaneRendererTests {
    /// The rows of a 0 dBFS signal at `dB` in a lane of `rows` rows at `range`.
    static func height(dB: Double, range: WaveformRange, rows: Double = 100) -> Int {
        Int((range.fraction(dB: dB) * rows).rounded())
    }

    /// The inputs of `session` at `range`.
    static func inputs(
        _ session: Session, peaks: [PeakColumn], range: WaveformRange
    ) -> LaneInputs {
        var inputs = Self.inputs(session, peaks: peaks)
        inputs.range = range
        return inputs
    }

    /// The rows of lane 0 in `column` of a draw at scale 2 that hold the peak color.
    static func peakRows(_ pixels: OwnedPixels, column: Int = 0, count rows: Int = 200) -> Int {
        (0..<rows).filter { pixels.pixel(column, $0) == LanePalette.light.peak }.count
    }

    /// The rows that one column of `value` draws at each range at scale 2 (200 rows).
    static func drawn(_ value: UInt16, at range: WaveformRange) throws -> Int {
        let bins = [PeakColumn(peak: value, rms: 0)]
        let inputs = Self.inputs(try Self.session(), peaks: bins, range: range)
        return Self.peakRows(try Self.render(inputs, width: 4, scale: 2))
    }

    /// A column at -24.0 dBFS (4135 of 65535) draws (R - 24) / R of the 200 rows, and a column at
    /// 0 dBFS draws all of them, at each range.
    @Test func theRangeSetsTheWaveformHeight() throws {
        let expected: [WaveformRange: Int] = [
            .db24: 0, .db36: 67, .db48: 100, .db60: 120, .db72: 133, .db84: 143, .db96: 150, .db120: 160,
            .db145: 167,
        ]
        for range in WaveformRange.allCases {
            #expect(try Self.drawn(4135, at: range) == expected[range], "-24 dBFS at \(range.rawValue) dB")
            #expect(try Self.drawn(65535, at: range) == 200, "0 dBFS at \(range.rawValue) dB")
        }
    }

    /// A column at -110 dBFS (13,582 of `UInt32.max`) draws 35 / 145 of the 200 rows at 145 dB: 48 rows,
    /// within one. At 96 dB it draws none: the signal is under the range.
    @Test func aQuietSignalDrawsAt145() throws {
        let bins = [PeakColumn(peak32: 13_582, rms32: 0)]
        let inputs = Self.inputs(try Self.session(), peaks: bins, range: .db145)
        let rows = Self.peakRows(try Self.render(inputs, width: 4, scale: 2))
        #expect(abs(rows - 48) <= 1, "-110 dBFS at 145 dB drew \(rows) rows")
        let shallow = Self.inputs(try Self.session(), peaks: bins, range: .db96)
        #expect(Self.peakRows(try Self.render(shallow, width: 4, scale: 2)) == 0, "-110 dBFS is under 96 dB")
    }

    /// A column at -1.0 dBFS (58409) draws (R - 1) / R of the 200 rows: the range reads a level and
    /// never adds a gain, so the top of a loud signal stays under the lane top.
    @Test func theZoomNeverCutsTheTop() throws {
        let expected: [WaveformRange: Int] = [
            .db24: 192, .db36: 194, .db48: 196, .db60: 197, .db72: 197, .db84: 198, .db96: 198, .db120: 198,
            .db145: 199,
        ]
        for range in WaveformRange.allCases {
            #expect(try Self.drawn(58409, at: range) == expected[range], "-1 dBFS at \(range.rawValue) dB")
        }
    }

    /// A clip at -6 dB with a 0 dBFS signal: the gain line is on the top row of the waveform, and
    /// on the y of `LaneGeometry.gainLineY` to one row, at each range.
    @Test func theLineIsOnTheWaveformTop() throws {
        let session = try Self.session(length: Self.envelopeLength, clipGain: -6)
        for range in WaveformRange.allCases {
            let inputs = Self.inputs(session, peaks: Self.fullPeaks(), range: range)
            let pixels = try Self.render(inputs, width: 400)
            let lane = try #require(inputs.session.tracks.first)
            let y = try #require(inputs.geometry).gainLineY(
                lane.clips[lane.clips.startIndex], trackGain: lane.gain, lane: 0)

            let line = Self.rows(pixels, column: 200, LanePalette.light.label)
            #expect(line.count == 1 && abs(Double(line[0]) - y) <= 0.5, "line \(line) at y \(y), \(range.rawValue) dB")
            let top = Self.rows(pixels, column: 200, LanePalette.light.peak).first
            #expect(top == line.first.map { $0 + 1 }, "the waveform starts under the line at \(range.rawValue) dB")
        }
    }

    /// The fade line of a column in the fade-in marks the top of the waveform of that column at each
    /// range. Column 10 is at 2816 / 25600 of the fade-in: a factor of 0.172, -15.3 dB.
    @Test func theFadeLineFollowsTheRange() throws {
        let full = Array(repeating: PeakColumn(peak: 65535, rms: 0), count: 400)
        let dB = 20 * log10(Self.factor(10 * 256))
        for range in WaveformRange.allCases {
            let inputs = Self.inputs(try Self.fadedSession(), peaks: full, range: range)
            let pixels = try Self.render(inputs, width: 400)

            let row = 100 - Self.height(dB: dB, range: range)
            #expect(
                Self.rows(pixels, column: 10, LanePalette.light.label) == [row], "fade line at \(range.rawValue) dB")
        }
    }

    /// The line of a crossfade half over the box of its neighbor is at the top of its waveform at each
    /// range: A over B at the column 220, 20 pt after the join, at scale 2 (200 rows).
    @Test func theCrossfadeLineFollowsTheRange() throws {
        let dB = 20 * log10(CrossfadeRendererTests.a(220 * 128))
        for range in WaveformRange.allCases {
            var inputs = try CrossfadeRendererTests.inputs()
            inputs.range = range
            let pixels = try CrossfadeRendererTests.render(inputs)

            let row = 200 - Self.height(dB: dB, range: range, rows: 200)
            let rows = CrossfadeRendererTests.labelRows(pixels, 220)
            #expect(rows.contains { abs($0 - row) <= 1 }, "A over B: row \(row) in \(rows) at \(range.rawValue) dB")
        }
    }

    /// A clip at 0 dB with a ride of -6 dB over its length: the line is at 10 pt at 60 dB and at
    /// 25 pt at 24 dB, the top of the waveform at each range.
    @Test func theLayeredLineFollowsTheRange() throws {
        let session = try Self.envelopeSession([(0, -6), (Self.envelopeLength, -6)])
        for range in WaveformRange.allCases {
            let inputs = Self.inputs(session, peaks: Self.fullPeaks(), range: range)
            let pixels = try Self.render(inputs, width: 400)

            let row = 100 - Self.height(dB: -6, range: range)
            #expect(
                Self.rows(pixels, column: 200, LanePalette.light.label) == [row], "ride line at \(range.rawValue) dB")
            if range == .db60 { #expect(row == 10) }
            if range == .db24 { #expect(row == 25) }
        }
    }

    /// The live take draws the columns of its bins with the range: the rows of a live column of
    /// 0.5 peak and 0.25 RMS are those of the same column of a clip, at each range.
    @Test func theLiveTakeUsesTheRange() throws {
        var peaks = LivePeaks(origin: 0, startHostNanos: 0, rate: 48_000)
        peaks.add(peak: 0.5, rms: 0.25, span: 0..<100_000_000, latencyNanos: 0, now: 100_000_000)
        let take = LiveLanes.Take(number: 1, finalizing: false, head: 4_800, tracks: ["t1": (peaks, .recording)])
        let live = LiveLanes(take: take)
        let palette = LanePalette.light.live
        let session = try Self.session()
        let expected = (peak: 32768.0, rms: 16384.0)
        for range in WaveformRange.allCases {
            let inputs = Self.inputs(session, peaks: [], range: range)
            let pixels = OwnedPixels(try #require(laneWindow(inputs, width: 20)))
            pixels.draw { LaneRenderer().draw(inputs, .light, live: live, into: $0) }

            func rows(_ color: UInt32) -> Int { (0..<100).filter { pixels.pixel(10, $0) == color }.count }
            let peak = Self.height(dB: 20 * log10(expected.peak / 65535), range: range)
            let rms = Self.height(dB: 20 * log10(expected.rms / 65535), range: range)
            #expect(rows(palette.peak) == peak - rms, "live peak rows at \(range.rawValue) dB")
            #expect(rows(palette.rms) == rms, "live RMS rows at \(range.rawValue) dB")
        }
    }
}
