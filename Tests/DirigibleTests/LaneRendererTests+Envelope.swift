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
        // The bar edge takes row 14 of the waveform.
        #expect(Self.drawn(plain, column: 150) == 99, "the control column has no envelope")
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

    /// Decision 0060: a binary search finds the first point of the draw rect, so the draw cost does
    /// not grow with the points before it. The walk of a rect late in a dense envelope starts at the
    /// first point after the first column, and still gives the same gain after a lower column.
    @Test func theWalkOfADrawRectLateInADenseEnvelopeStartsAtItsFirstPoint() throws {
        let points = (0..<10_000).map { GainEnvelope.Point(frame: Frames($0 * 100), gain: Gain(dB: -Double($0 % 7))!) }
        let envelope = try #require(GainEnvelope(points))
        var column = ColumnEnvelope(layers: [envelope], first: 700_050, step: 100)

        #expect(column.layers.map(\.next) == [7_001], "the first point after frame 700,050 is at 700,100")
        let first = column.gain(0)
        let expected = max(envelope.gain(at: 700_050), envelope.gain(at: 700_150), points[7_001].gain.dB)
        #expect(first == expected)
        _ = column.gain(30)
        #expect(column.gain(0) == first, "a lower column walks again from the first point of the rect")
    }

    /// A clip with a ride and no envelope draws its waveform and its line at the heard
    /// gain, as an envelope of the same gain does.
    @Test func aRiddenClipDrawsTheHeardGain() throws {
        var session = try Self.session(length: Self.envelopeLength)
        let ride = try #require(
            GainEnvelope([
                GainEnvelope.Point(frame: 0, gain: Gain(dB: -6)!),
                GainEnvelope.Point(frame: Frames(Self.envelopeLength), gain: Gain(dB: -6)!),
            ]))
        try session.setRides(["c1": ride])
        let pixels = try Self.render(Self.inputs(session, peaks: Self.fullPeaks()), width: 400)

        #expect(Self.rows(pixels, column: 150, LanePalette.light.label) == [100 - Self.height(dB: -6)])
        let drawn = Self.drawn(pixels, column: 150)
        #expect(abs(drawn - Self.height(dB: -6)) <= 1, "the column has the -6 dB height: \(drawn) rows")
    }

    /// A ridden clip at 100 pt that plays its file from frame 51,200: column c reads the file frame
    /// 51,200 + (c - 100) x 256. The ride is -6 dB on the first 100 pt of the window and -2 dB after,
    /// so the line and the waveform of column 150 are at -6 dB and of column 250 at -2 dB. A walk
    /// that drops the start or adds it reads -2 dB at column 150.
    @Test func aRiddenClipWithAnOffsetDrawsTheGainOfItsFileFrames() throws {
        let (offset, start, length) = (51_200, 25_600, Self.envelopeLength)
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f1", path: "f1.wav", layout: .mono, length: Frames(offset + length)))
        try session.addTrack("t1", name: "T1", layout: .mono)
        try session.place(
            Clip(id: "c1", file: "f1", start: Frames(start), offset: Frames(offset), length: Frames(length)), on: "t1")
        let ride = try #require(
            GainEnvelope(
                [(0, -6.0), (25_599, -6), (25_601, -2), (length, -2)].map {
                    GainEnvelope.Point(frame: Frames(offset + $0.0), gain: Gain(dB: $0.1)!)
                }))
        try session.setRides(["c1": ride])
        let peaks = Array(repeating: PeakColumn(peak: 65535, rms: 0), count: (offset + length) / 256)
        let pixels = try Self.render(Self.inputs(session, peaks: peaks), width: 520)

        for (column, dB) in [(150, -6.0), (250, -2.0)] {
            #expect(Self.rows(pixels, column: column, LanePalette.light.label) == [100 - Self.height(dB: dB)])
            let drawn = Self.drawn(pixels, column: column)
            #expect(abs(drawn - Self.height(dB: dB)) <= 1, "column \(column): \(drawn) rows, not \(dB) dB")
        }
    }

    /// The column gain of two layers is the maximum of their sum over the frames of the
    /// column, against a brute-force read of `Clip.layerGain`. Seeded layers put points of both in
    /// one column; a literal case has the envelope peak at the frame 1,010 and the ride peak at the
    /// frame 1,090 of one column, where max(E) + max(R) is 10 dB over the heard peak.
    @Test func maxOfTheLayers() throws {
        var random = SplitMix(seed: 5)
        func layer(_ count: Int) throws -> GainEnvelope {
            let frames = Set((0..<count).map { _ in Int.random(in: 0...20_000, using: &random) }).sorted()
            return try #require(
                GainEnvelope(
                    frames.map {
                        GainEnvelope.Point(frame: Frames($0), gain: Gain(dB: .random(in: -20...6, using: &random))!)
                    }))
        }
        func literal(_ points: [(Int, Double)]) throws -> GainEnvelope {
            try #require(GainEnvelope(points.map { GainEnvelope.Point(frame: Frames($0.0), gain: Gain(dB: $0.1)!) }))
        }
        let cases = try [
            (layer(60), layer(300), 37.5),
            (
                literal([(1_000, -10), (1_010, 0), (1_020, -10)]), literal([(1_080, -10), (1_090, 0), (1_100, -10)]),
                100
            ),
        ]
        var misses: [String] = []
        for (number, (envelope, ride, step)) in cases.enumerated() {
            let clip = Clip(id: "c1", file: "f1", start: 0, offset: 0, length: 30_000, envelope: envelope, ride: ride)
            var column = ColumnEnvelope(layers: [envelope, ride], first: 1_000, step: step)
            // In order, then a lower column, which walks again from the first point of the rect.
            for index in Array(0..<200) + [3, 4] {
                let start = 1_000 + Double(index) * step
                let (low, high) = (Int(start.rounded(.down)), Int((start + step).rounded(.up)))
                let heard = (low...high).map { clip.layerGain(at: Frames($0)) }.max()!
                let gain = column.gain(index)
                if abs(gain - heard) > 1e-9 { misses.append("case \(number), column \(index): \(gain), \(heard)") }
            }
        }
        #expect(misses.count == 0, "columns off the heard peak: \(misses.prefix(5))")
    }

    /// One renderer keeps the layer gains of a clip between draws. After each change of the ride,
    /// the envelope, the clip start, the zoom, or the window, its pixels equal those of a new
    /// renderer, and each change of the inputs moves pixels. The ride steps at the middle of the
    /// file, so a kept gain of other inputs draws the line and the waveform at the wrong height.
    @Test func eachDrawAfterAChangeOfTheGainInputsEqualsANewRenderer() throws {
        let length = Self.envelopeLength
        func session(start: Int = 0, high: Double = -2, envelope: Double? = nil) throws -> Session {
            var session = Session(sampleRate: 48_000)
            try session.addFile(AudioFile(id: "f1", path: "f1.wav", layout: .mono, length: Frames(length)))
            try session.addTrack("t1", name: "T1", layout: .mono)
            try session.place(
                Clip(id: "c1", file: "f1", start: Frames(start), offset: 0, length: Frames(length)), on: "t1")
            func layer(_ points: [(Int, Double)]) throws -> GainEnvelope {
                try #require(
                    GainEnvelope(points.map { GainEnvelope.Point(frame: Frames($0.0), gain: Gain(dB: $0.1)!) }))
            }
            try session.setRides(["c1": layer([(0, -6), (length / 2, -6), (length / 2 + 1, high), (length, high)])])
            if let envelope { try session.setEnvelopes(["c1": layer([(0, envelope), (length, envelope)])]) }
            return session
        }
        var zoomed = Self.inputs(try session(start: 25_600, high: 4, envelope: -8), peaks: Self.fullPeaks())
        zoomed.scale = TimelineScale(framesPerPoint: 128)
        let steps: [(String, LaneInputs, x: Double)] = [
            ("first draw", Self.inputs(try session(), peaks: Self.fullPeaks()), 0),
            ("ride", Self.inputs(try session(high: 4), peaks: Self.fullPeaks()), 0),
            ("envelope", Self.inputs(try session(high: 4, envelope: -8), peaks: Self.fullPeaks()), 0),
            ("start", Self.inputs(try session(start: 25_600, high: 4, envelope: -8), peaks: Self.fullPeaks()), 0),
            ("zoom", zoomed, 0), ("scroll", zoomed, 60), ("scroll in the kept columns", zoomed, 300),
        ]
        let renderer = LaneRenderer()
        var previous: LaneInputs?
        for (name, inputs, x) in steps {
            let window = try #require(laneWindow(inputs, x: x, width: 400))
            func draw(_ renderer: LaneRenderer, _ inputs: LaneInputs) -> [[UInt32]] {
                let pixels = OwnedPixels(window)
                pixels.draw { renderer.draw(inputs, .light, into: $0) }
                return window.pixels.rows.map { pixels.row($0) }
            }
            let fresh = draw(LaneRenderer(), inputs)
            #expect(draw(renderer, inputs) == fresh, "\(name): the kept renderer draws other pixels")
            if let previous, previous != inputs {
                #expect(draw(LaneRenderer(), previous) != fresh, "\(name): the change moves no pixel")
            }
            previous = inputs
        }
    }

    /// The lanes of `session(length:)` at 256 frames per point, with the same ride on `c1` and `c2`
    /// and a full peak in each column.
    static func riddenInputs(length: Int) throws -> LaneInputs {
        var session = try Self.session(length: length)
        let ride = try #require(
            GainEnvelope(
                [(0, -6.0), (length / 2, -6), (length / 2 + 1, 4), (length, 4)].map {
                    GainEnvelope.Point(frame: Frames($0.0), gain: Gain(dB: $0.1)!)
                }))
        try session.setRides(["c1": ride, "c2": ride])
        return Self.inputs(session, peaks: Array(repeating: PeakColumn(peak: 65535, rms: 0), count: length / 256))
    }

    /// A draw of unchanged clips reads the kept layer gains and walks no layer.
    @Test func aSecondDrawOfUnchangedClipsWalksNoLayer() throws {
        let inputs = try Self.riddenInputs(length: Self.envelopeLength)
        let pixels = OwnedPixels(try #require(laneWindow(inputs, width: 400)))
        let renderer = LaneRenderer()
        pixels.draw { renderer.draw(inputs, .light, into: $0) }
        #expect(renderer.walks == 2)
        pixels.draw { renderer.draw(inputs, .light, into: $0) }
        #expect(renderer.walks == 2)
    }

    /// A scroll draws only the new columns. The first scroll past the kept columns walks once,
    /// with one window width more on each side, so the next scroll in that width walks no layer.
    @Test func aScrollWalksOnceThenReadsTheKeptColumns() throws {
        let inputs = try Self.riddenInputs(length: 4 * Self.envelopeLength)
        let renderer = LaneRenderer()
        var walks: [Int] = []
        for (x, strip) in [(0.0, 0..<400), (60, 400..<460), (120, 460..<520), (0, 0..<60)] {
            let window = try #require(laneWindow(inputs, x: x, width: 400))
            let before = renderer.walks
            OwnedPixels(window).draw(PixelRect(columns: strip, rows: window.pixels.rows)) {
                renderer.draw(inputs, .light, into: $0)
            }
            walks.append(renderer.walks - before)
        }
        #expect(walks == [2, 2, 0, 0])
    }

    /// One display event draws a part on each lane, as `LaneSurfaces.show` draws them. The part of
    /// one lane keeps the layer gains of the other, so a second event walks no layer.
    @Test func aSecondDisplayOfPartsOnTwoLanesWalksNoLayer() throws {
        let inputs = try Self.riddenInputs(length: Self.envelopeLength)
        let window = try #require(laneWindow(inputs, width: 400))
        let pixels = OwnedPixels(window)
        let renderer = LaneRenderer()
        var walks: [Int] = []
        for _ in 0..<3 {
            let before = renderer.walks
            renderer.display {
                for lane in 0..<2 {
                    pixels.draw(PixelRect(columns: window.pixels.columns, rows: window.rows(of: lane..<lane + 1))) {
                        renderer.draw(inputs, .light, into: $0)
                    }
                }
            }
            walks.append(renderer.walks - before)
        }
        #expect(walks == [2, 0, 0])
    }
}
