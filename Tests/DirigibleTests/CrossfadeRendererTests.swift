import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Criteria R1 to R4 and the G11 draw of run 11c-2: the X of a crossfade. At 256 frames per point,
/// 100 pt lanes, and scale 2, a lane has 200 rows and a column has 128 frames. On t1, clip A (file
/// f1, offset 0) is x 0 to 100 and clip B (file f2, offset 25,600) is x 100 to 200, both of a
/// 0 dBFS signal. The crossfade at J (column 200) has L = 10,240 frames, so L/2 is 20 pt (40
/// columns): A sounds to column 240, and B from column 160.
struct CrossfadeRendererTests {
    static let label = LanePalette.light.label

    /// The inputs with A and B of `points` pt each, at `gain` dB, and a crossfade of `length`.
    static func inputs(points: Double = 100, gain: Double = 0, length: Frames = 10_240) throws -> LaneInputs {
        let frames = Frames(Int(points * 256))
        var session = Session(sampleRate: 48_000)
        for file in ["f1", "f2"] as [FileID] {
            try session.addFile(AudioFile(id: file, path: "\(file).wav", layout: .mono, length: 102_400))
        }
        try session.addTrack("t1", name: "T1", layout: .mono)
        try session.addTrack("t2", name: "T2", layout: .mono)
        let clipGain = try #require(Gain(dB: gain))
        try session.place(Clip(id: "A", file: "f1", start: 0, offset: 0, length: frames, gain: clipGain), on: "t1")
        try session.place(
            Clip(id: "B", file: "f2", start: frames, offset: 25_600, length: frames, gain: clipGain), on: "t1")
        try session.setCrossfades(["A": length])
        return LaneRendererTests.inputs(session, peaks: GainLineRendererTests.full(102_400))
    }

    /// The pixels of the document points `x ..< x + width`.
    static func render(_ inputs: LaneInputs, x: Double = 0, width: Double = 220) throws -> OwnedPixels {
        let pixels = OwnedPixels(try #require(laneWindow(inputs, x: x, width: width, scale: 2)))
        pixels.draw { LaneRenderer().draw(inputs, .light, into: $0) }
        return pixels
    }

    /// The rows of lane 0 in `column` that have the label color.
    static func labelRows(_ pixels: OwnedPixels, _ column: Int) -> [Int] {
        (0..<200).filter { pixels.pixel(column, $0) == label }
    }

    /// The row of a line at the fade factor `factor` with `gain` dB: 200 - the rows of a 0 dBFS signal.
    static func row(_ factor: Double, gain: Double = 0) -> Int {
        200 - Int((min(max((gain + 20 * log10(factor) + 60) / 60, 0), 1) * 200).rounded())
    }

    /// A's fade-out at its sounding frame `k` (sounding length 30,720), and B's fade-in at its
    /// sounding frame `k`.
    static func a(_ k: Int) -> Double { sin(.pi / 2 * Double(30_720 - k) / 10_240) }
    static func b(_ k: Int) -> Double { sin(.pi / 2 * Double(k) / 10_240) }

    /// R1: the column at J - 3 of A, the last column of A left of the 2 pt join (decision 0017), takes
    /// the fade-out curve within 1 px (fail value: the top row). The join covers the columns at J - 2
    /// to J + 1 over the whole lane. With no peaks for B, no waveform shows in B's box: A draws its
    /// waveform in its own box only.
    @Test func theWaveformTakesTheCrossfadeCurve() throws {
        let pixels = try Self.render(try Self.inputs())
        let top = try #require((0..<200).first { pixels.pixel(197, $0) != LanePalette.light.clip })
        #expect(abs(top - Self.row(Self.a(197 * 128))) <= 1, "top row \(top)")
        for column in 198...201 {
            #expect(
                (0..<200).allSatisfy { pixels.pixel(column, $0) == LanePalette.light.join },
                "the join covers the column \(column)")
        }

        var inputs = try Self.inputs()
        inputs.peaks["f2"] = .unavailable
        let alone = try Self.render(inputs)
        let waveform = (200..<240).filter { column in
            (0..<200).contains { [LanePalette.light.peak, LanePalette.light.rms].contains(alone.pixel(column, $0)) }
        }
        #expect(waveform.isEmpty, "A's waveform in B's box: \(waveform)")
    }

    /// R2: A's line goes on over B's box, and B's line over A's box, over the waveforms (fail
    /// value: the waveform color there). A box under 12 pt draws no line; a box of 12 pt does.
    @Test func theLinesCrossAtTheJoin() throws {
        let pixels = try Self.render(try Self.inputs())
        let overB = Self.row(Self.a(220 * 128))
        let overA = Self.row(Self.b(180 * 128 - 20_480 + 128))
        #expect(Self.labelRows(pixels, 220).contains { abs($0 - overB) <= 1 }, "A over B: \(overB)")
        #expect(Self.labelRows(pixels, 180).contains { abs($0 - overA) <= 1 }, "B over A: \(overA)")

        let narrow = try Self.render(try Self.inputs(points: 11, length: 1_024))
        #expect(GainLineRendererTests.noLabel(narrow), "11 pt boxes")
        let twelve = try Self.render(try Self.inputs(points: 12, length: 1_024))
        #expect(!GainLineRendererTests.noLabel(twelve), "12 pt boxes")
    }

    /// R3: a draw of x 100 to 220 holds no frame of A's box, but A's line reaches into it (fail
    /// value: the `clips(overlapping:)` query draws no line).
    @Test func aClipLeftOfTheDrawStillDrawsItsLine() throws {
        let pixels = try Self.render(try Self.inputs(), x: 100, width: 120)
        let overB = Self.row(Self.a(220 * 128))
        #expect(Self.labelRows(pixels, 220).contains { abs($0 - overB) <= 1 }, "A over B: \(overB)")
    }

    /// R4: draws of columns split at J and in the crossfade give the pixels of one draw.
    @Test func aPartialRedrawEqualsAFullDraw() throws {
        let inputs = try Self.inputs(gain: -6)
        let window = try #require(laneWindow(inputs, width: 220, scale: 2))
        let one = OwnedPixels(window, fill: 0xFFAB_CDEF)
        one.draw { LaneRenderer().draw(inputs, .light, into: $0) }
        let rows = window.pixels.rows
        let parts = OwnedPixels(window, fill: 0xFFAB_CDEF)
        for columns in [0..<200, 200..<230, 230..<440] {
            parts.draw(PixelRect(columns: columns, rows: rows)) { LaneRenderer().draw(inputs, .light, into: $0) }
        }
        let wrong = rows.flatMap { row in window.pixels.columns.filter { one.pixel($0, row) != parts.pixel($0, row) } }
        #expect(wrong.isEmpty, "\(wrong.count) pixels differ, the first at column \(wrong.first ?? 0)")
    }

    /// G11: at -6 dB the gain line (row 20) stops at the crossfade half of A (column 160) and
    /// starts at the half of B (column 240). Fail value: the line on row 20 up to J.
    @Test func theGainLineStopsAtTheCrossfade() throws {
        let pixels = try Self.render(try Self.inputs(gain: -6))
        let line = Set(GainLineRendererTests.labelColumns(pixels, row: 20))
        #expect(Set(20..<160).isSubset(of: line), "A's line before the half")
        #expect(line.isDisjoint(with: 180..<220), "no gain line in the crossfade")
        #expect(Set(250..<380).isSubset(of: line), "B's line after the half")
    }
}
