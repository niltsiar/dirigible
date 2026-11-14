import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The clip bar (timeline clarity C19, C20, C24, C25): a band at the top of each clip box of 60 pt
/// or wider in a lane of 60 pt or taller, with the clip name in it. One clip `c1` on `t1` from 0,
/// at 256 frames per point. A 100 pt box has its start handle at 0 to 8 pt and its end handle at
/// 92 to 100 pt, rows 0 to 8 pt, so the tests read the columns between them.
@MainActor struct LaneRendererBarTests {
    nonisolated static let palettes = [LanePalette.light, LanePalette.dark(accent: 0xFFFF_2D55)]
    static let quiet = PeakColumn(peak: 0, rms: 0)
    static let loud = PeakColumn(peak: 65535, rms: 0)

    /// `c1` of `frames` frames, with the fades and the envelope when given.
    static func session(
        frames: Int = 25_600, path: String = "f1.wav", fades: Fades? = nil, envelope: GainEnvelope? = nil
    ) throws -> Session {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f1", path: path, layout: .mono, length: Frames(frames)))
        try session.addTrack("t1", name: "T1", layout: .mono)
        try session.place(Clip(id: "c1", file: "f1", start: 0, offset: 0, length: Frames(frames)), on: "t1")
        if let fades { try session.setFades(["c1": fades]) }
        if let envelope { try session.setEnvelopes(["c1": envelope]) }
        return session
    }

    static func inputs(_ session: Session, _ column: PeakColumn = quiet, laneHeight: Double = 100) -> LaneInputs {
        var inputs = LaneRendererTests.inputs(session, peaks: Array(repeating: column, count: 400))
        inputs.selection = .none
        inputs.laneHeight = laneHeight
        return inputs
    }

    /// The lane pixels with no label.
    static func plain(_ inputs: LaneInputs, _ palette: LanePalette, scale: Double, width: Double = 120) throws
        -> OwnedPixels
    {
        let pixels = OwnedPixels(try #require(laneWindow(inputs, width: width, scale: scale)))
        pixels.draw { LaneRenderer().draw(inputs, palette, into: $0) }
        return pixels
    }

    /// The lane pixels as the view draws them, with the labels.
    static func labeled(_ inputs: LaneInputs, _ palette: LanePalette, scale: Double, width: Double = 120) throws
        -> OwnedPixels
    {
        OwnedPixels.render(inputs, try #require(laneWindow(inputs, width: width, scale: scale)), palette)
    }

    /// The chip of the one clip label of `inputs`.
    static func chip(_ inputs: LaneInputs, scale: Double) throws -> NSRect {
        let pixels = OwnedPixels(try #require(laneWindow(inputs, width: 120, scale: scale)))
        var chip: NSRect?
        pixels.draw { chip = ClipLabel.labels(inputs, live: nil, in: $0).first?.chip }
        return try #require(chip, "the clip has a label")
    }

    @Test(arguments: palettes, [1.0, 2.0])
    func theClipBarDrawsOnlyOnWideBoxesInTallLanes(palette: LanePalette, scale: Double) throws {
        let s = Int(scale)
        let (column, rows, edge) = (30 * s, 4 * s..<14 * s, 15 * s - 1)
        func isBar(_ pixels: OwnedPixels) -> Bool { rows.allSatisfy { pixels.pixel(column, $0) == palette.bar } }
        func isClip(_ pixels: OwnedPixels) -> Bool { rows.allSatisfy { pixels.pixel(column, $0) == palette.clip } }

        let wide = try Self.plain(Self.inputs(try Self.session(frames: 15_360), laneHeight: 60), palette, scale: scale)
        #expect(isBar(wide), "a box of 60 pt in a lane of 60 pt has the bar")
        #expect(wide.pixel(column, edge) == palette.barEdge, "the edge in the bar bottom row")
        #expect(wide.pixel(column, edge + 1) == palette.clip, "the clip fill under the bar")

        let narrow = try Self.plain(
            Self.inputs(try Self.session(frames: 15_334), laneHeight: 60), palette, scale: scale)
        #expect(isClip(narrow), "a box of 59.9 pt has no bar")
        #expect(narrow.pixel(column, edge) == palette.clip, "and no edge")
        let short = try Self.plain(Self.inputs(try Self.session(), laneHeight: 59), palette, scale: scale)
        #expect(isClip(short), "a lane of 59 pt has no bar")

        let loud = try Self.plain(Self.inputs(try Self.session(), Self.loud), palette, scale: scale)
        #expect(loud.pixel(column, 4 * s) == palette.peak, "a full-scale column covers the bar")

        var missing = Self.inputs(try Self.session(frames: 15_360), laneHeight: 60)
        missing.missingMedia = ["f1": .missing]
        let red = try Self.plain(missing, palette, scale: scale)
        #expect(rows.allSatisfy { red.pixel(column, $0) == palette.missing }, "a missing-media box has no bar")
        #expect(red.pixel(column, edge) == palette.missing, "and no edge")

        // 7,680 frames of the file are real: the bar runs to the red column at 30 pt.
        var cut = Self.inputs(try Self.session(frames: 15_360), laneHeight: 60)
        cut.missingMedia = ["f1": .short(7_680)]
        let half = try Self.plain(cut, palette, scale: scale)
        for left in [20 * s, 30 * s - 1] {
            #expect(rows.allSatisfy { half.pixel(left, $0) == palette.bar }, "the bar left of the red column \(left)")
            #expect(half.pixel(left, edge) == palette.barEdge, "the edge left of it")
        }
        for right in [30 * s, 40 * s] {
            #expect(rows.allSatisfy { half.pixel(right, $0) == palette.missing }, "the red from column \(right)")
            #expect(half.pixel(right, edge) == palette.missing, "no edge in the red")
            #expect(half.pixel(right, 60 * s - 1) == palette.missingOutline, "the outline in the red")
        }

        var band = Self.inputs(try Self.session(frames: 15_360), laneHeight: 60)
        band.selection = .range(Marks(inPoint: 0, outPoint: 15_360, tracks: ["t1"]))
        #expect(
            try Self.plain(band, palette, scale: scale).pixel(column, 4 * s) == palette.selected(palette.bar),
            "the range band over the bar")
        var set = Self.inputs(try Self.session(frames: 15_360), laneHeight: 60)
        set.selection = .clips(try #require(ClipSet(["c1"])))
        #expect(
            try Self.plain(set, palette, scale: scale).pixel(column, 4 * s) == palette.tinted(palette.bar),
            "the clip set tint over the bar")

        // A partial draw of the bar columns gives the pixels of the full draw.
        let inputs = Self.inputs(try Self.session(frames: 15_360), laneHeight: 60)
        let full = try Self.plain(inputs, palette, scale: scale)
        let part = OwnedPixels(try #require(laneWindow(inputs, width: 120, scale: scale)))
        part.draw(PixelRect(columns: 20 * s..<40 * s, rows: 0..<60 * s)) {
            LaneRenderer().draw(inputs, palette, into: $0)
        }
        let same = (20 * s..<40 * s).allSatisfy { c in
            (0..<60 * s).allSatisfy { full.pixel(c, $0) == part.pixel(c, $0) }
        }
        #expect(same, "a partial draw")
    }

    @Test(arguments: palettes, [1.0, 2.0])
    func theClipLabelSitsInTheBar(palette: LanePalette, scale: Double) throws {
        let s = Int(scale)
        let session = try Self.session(path: "take-interview.wav")

        let inputs = Self.inputs(session)
        let chip = try Self.chip(inputs, scale: scale)
        #expect(chip.minY == 0 && chip.minX == 10 && chip.height == ClipLabel.height, "the chip: \(chip)")
        // Under the start handle at rest (rows 1 to 7 pt, in the label color): the rows under it are the color test.
        let quiet = try Self.labeled(inputs, palette, scale: scale)
        let under = (1 * s..<9 * s).allSatisfy { c in (8 * s..<14 * s).allSatisfy { quiet.pixel(c, $0) == palette.bar }
        }
        #expect(under, "no glyph pixel under the start handle")

        let loud = try Self.labeled(Self.inputs(session, Self.loud), palette, scale: scale)
        let column = 11 * s
        #expect((s..<14 * s).allSatisfy { loud.pixel(column, $0) == palette.bar }, "the bar in the chip rows")
        #expect(loud.pixel(column, 15 * s) == palette.peak, "the waveform under the chip")

        let flat = Self.inputs(session, laneHeight: 50)
        #expect(try Self.chip(flat, scale: scale).minY == 0, "the chip at the box top")
        let low = try Self.labeled(flat, palette, scale: scale)
        #expect(low.pixel(column, 8 * s) == palette.clip, "a lane of 50 pt: the chip on the clip fill")
    }

    /// The pixels of `rect` (points) with a point more in each direction.
    static func samePixels(_ rect: CGRect, _ a: OwnedPixels, _ b: OwnedPixels, scale: Double) -> Bool {
        let (x0, x1) = (max(0, Int((rect.minX - 1) * scale)), Int((rect.maxX + 1) * scale))
        let (y0, y1) = (max(0, Int((rect.minY - 1) * scale)), Int((rect.maxY + 1) * scale))
        return (x0..<x1).allSatisfy { c in (y0..<y1).allSatisfy { a.pixel(c, $0) == b.pixel(c, $0) } }
    }

    /// C24, in a lane of 100 pt with low peaks, so only the text and the controls show: the pixels of each
    /// handle rect and each disc square, plus 1 pt, are the same with and without the labels.
    @Test(arguments: palettes, [1.0, 2.0])
    func theClipNameCoversNoFadeHandleAndNoEnvelopeDisc(palette: LanePalette, scale: Double) throws {
        let long = "a-long-take-name-for-the-guest-interview.wav"
        let fadeIn = try Self.session(path: "take-interview.wav", fades: Fades(fadeIn: 7_680, fadeOut: 0))
        let narrow = try Self.session(frames: 15_360, path: long)
        let envelope = try #require(GainEnvelope([GainEnvelope.Point(frame: 5_120, gain: Gain(dB: 0)!)]))
        let disc = try Self.session(path: long, envelope: envelope)

        for (name, session, chipStart, chipEnd, count) in [
            ("a 30 pt fade-in", fadeIn, 36.0, 90.0, 2), ("a 60 pt box", narrow, 10.0, 50.0, 2),
            ("a disc", disc, 10.0, 90.0, 3),
        ] {
            let inputs = Self.inputs(session)
            let geometry = try #require(LaneGeometry(scale: inputs.scale, laneHeight: 100, range: .standard))
            let (clips, clip) = (session.tracks[0].clips, session.tracks[0].clips[0])
            let handles = geometry.fadeHandles(of: clip, at: 0, in: clips, lane: 0)
            let points = geometry.envelopePoints(of: clip, at: 0, in: clips, trackGain: session.tracks[0].gain, lane: 0)
            let r = LaneGeometry.pointRadius
            let controls =
                [handles.start, handles.end].compactMap { $0.map { CGRect($0.minX, $0.minY, $0.width, $0.height) } }
                + points.map { CGRect($0.x - r, $0.y - r, 2 * r, 2 * r) }
            #expect(controls.count == count, "\(name): the controls \(controls)")

            let chip = try Self.chip(inputs, scale: scale)
            let (with, without) = (
                try Self.labeled(inputs, palette, scale: scale), try Self.plain(inputs, palette, scale: scale)
            )
            #expect(chip.minX == chipStart && chip.maxX <= chipEnd, "\(name): the chip \(chip)")
            for control in controls {
                #expect(Self.samePixels(control, with, without, scale: scale), "\(name): text on \(control)")
            }
            let text = (Int(chip.minX * scale)..<Int(chip.maxX * scale)).contains { c in
                (0..<Int(chip.maxY * scale)).contains { with.pixel(c, $0) != without.pixel(c, $0) }
            }
            #expect(text, "\(name): the chip has text pixels")
        }
        #expect(try Self.chip(Self.inputs(narrow), scale: scale).maxX == 50, "the chip ends 10 pt before the box end")
    }

    @Test(arguments: palettes, [1.0, 2.0])
    func theBarEdgeShowsOverAFullScaleColumn(palette: LanePalette, scale: Double) throws {
        let s = Int(scale)
        let pixels = try Self.plain(Self.inputs(try Self.session(), Self.loud), palette, scale: scale)
        #expect(pixels.pixel(50 * s, 4 * s) == palette.peak, "the waveform over the bar")
        #expect(pixels.pixel(50 * s, 15 * s - 1) == palette.barEdge, "the edge over the waveform")
        #expect(pixels.pixel(50 * s, 15 * s) == palette.peak, "the waveform under the bar")
    }

    /// C53 of run 2026-10-28-timeline-edits: a strip of a still lane in a ripple drag gets the label
    /// only when the strip meets its chip, and the strip draw gives the pixels of the full draw.
    @Test(arguments: palettes, [1.0, 2.0])
    func aStripGetsTheLabelOnlyWhenItMeetsTheChip(palette: LanePalette, scale: Double) throws {
        let s = Int(scale)
        let inputs = Self.inputs(try Self.session(path: "take-interview.wav"))
        let chip = try Self.chip(inputs, scale: scale)
        let full = try Self.labeled(inputs, palette, scale: scale)
        #expect(chip.maxX < 92, "the strip from 92 pt is in the box of 100 pt and past the chip: \(chip)")
        for (columns, label) in [(92 * s..<98 * s, false), (12 * s..<18 * s, true)] {
            let strip = PixelRect(columns: columns, rows: 0..<100 * s)
            let part = OwnedPixels(try #require(laneWindow(inputs, width: 120, scale: scale)))
            var labels: [ClipLabel] = []
            part.draw(strip) { region in
                labels = ClipLabel.labels(inputs, live: nil, in: region)
                TimelineDocumentView.drawLanes(LaneRenderer(), inputs, palette, into: region)
            }
            #expect(labels.map(\.chip) == (label ? [chip] : []), "the strip \(columns), the chip \(chip)")
            let same = columns.allSatisfy { c in (0..<100 * s).allSatisfy { full.pixel(c, $0) == part.pixel(c, $0) } }
            #expect(same, "the strip \(columns) has the pixels of the full draw")
        }
    }
}

extension CGRect {
    fileprivate init(_ x: Double, _ y: Double, _ width: Double, _ height: Double) {
        self.init(x: x, y: y, width: width, height: height)
    }
}
