import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Run 2026-10-11-ui-polish-header C14: a clip label draws on a chip of the box fill, so it reads
/// over a loud waveform. The renderer draws no peak or RMS span in the chip, and each later pass
/// draws over the chip as over the rest of the box. The chip is at the top of the box, 10 pt from
/// its start. At 256 frames per point and scale 1, clip A of t1 is columns 0 ..< 100 and lane 0 is
/// rows 0 ..< 100.
@MainActor struct TimelineLabelTests {
    /// Full-scale peaks: the waveform covers the whole lane.
    static func inputs(path: String = "f1.wav") throws -> LaneInputs {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f1", path: path, layout: .mono, length: 51_200))
        try session.addTrack("t1", name: "T1", layout: .mono)
        try session.place(Clip(id: "A", file: "f1", start: 0, offset: 0, length: 25_600), on: "t1")
        let bins = Array(repeating: PeakColumn(peak: 65535, rms: 60000), count: 200)
        return LaneRendererTests.inputs(session, peaks: bins)
    }

    /// The pixels of the document points 0 ..< 120, as the view draws them, or in `rect` only.
    static func render(_ inputs: LaneInputs, _ palette: LanePalette, rect: PixelRect? = nil) throws -> OwnedPixels {
        let window = try #require(laneWindow(inputs, width: 120))
        guard let rect else { return OwnedPixels.render(inputs, window, palette) }
        let pixels = OwnedPixels.render(inputs, window, palette)
        pixels.draw(rect) { TimelineDocumentView.drawLanes(LaneRenderer(), inputs, palette, into: $0) }
        return pixels
    }

    /// The test pixel: inside the chip, left of the text, under the start handle, in the bar.
    static let (column, row) = (11, 8)

    @Test(arguments: [LanePalette.light, LanePalette.dark(accent: 0xFFFF_2D55)])
    func theLabelHasABacking(palette: LanePalette) throws {
        let inputs = try Self.inputs()
        #expect(try Self.render(inputs, palette).pixel(Self.column, Self.row) == palette.bar, "the bar")
        // A partial draw of the chip columns gives the pixels of the full draw.
        let full = try Self.render(inputs, palette)
        let part = try Self.render(inputs, palette, rect: PixelRect(columns: 0..<15, rows: 0..<100))
        #expect((0..<100).allSatisfy { full.pixel(Self.column, $0) == part.pixel(Self.column, $0) }, "a partial draw")

        var set = inputs
        set.selection = .clips(try #require(ClipSet(["A"])))
        let picked = try Self.render(set, palette)
        #expect(picked.pixel(Self.column, Self.row) == palette.tinted(palette.bar), "the tint of a set")
        #expect(picked.pixel(0, Self.row) == palette.outline, "the outline stays")

        var band = inputs
        band.selection = .range(Marks(inPoint: 0, outPoint: 25_600, tracks: ["t1"]))
        let selected = try Self.render(band, palette)
        #expect(selected.pixel(Self.column, Self.row) == palette.selected(palette.bar), "the band")

        var missing = inputs
        missing.missingMedia = ["f1": .missing]
        #expect(try Self.render(missing, palette).pixel(Self.column, Self.row) == palette.missing, "missing media")
    }

    /// The fade lines draw in the chip: the cut takes only the peak and RMS spans (premortem 6). A real
    /// chip lies between the fade handles, so this label has a chip over the fade-in of A.
    @Test func theFadeLinesDrawInTheChip() throws {
        let inputs = try CrossfadeRendererTests.inputs()
        var faded = inputs.session
        try faded.setFades(["A": try #require(Fades(fadeIn: 5_120, fadeOut: 0))])
        let fadedInputs = LaneInputs(
            session: faded, peaks: inputs.peaks, missingMedia: [:], selection: .none, scale: inputs.scale,
            laneHeight: inputs.laneHeight)
        let window = try #require(laneWindow(fadedInputs, width: 220, scale: 2))
        let box = NSRect(x: 0, y: 0, width: 100, height: 100)
        let labels = [
            ClipLabel(clip: "A", lane: 0, text: "A fade-in line", box: box, shown: [box], start: 0, end: 100)
        ]
        let chip = labels[0].cut(scale: 2).columns
        let plain = OwnedPixels(window)
        plain.draw { LaneRenderer().draw(fadedInputs, .light, into: $0) }
        let chipped = OwnedPixels(window)
        chipped.draw { LaneRenderer().draw(fadedInputs, .light, labels: labels, into: $0) }
        let (unfaded, label) = (try CrossfadeRendererTests.render(inputs), LanePalette.light.label)
        var lines = 0
        for column in chip {
            for row in 0..<200 where plain.pixel(column, row) == label {
                #expect(chipped.pixel(column, row) == label, "a label color pixel at \(column), \(row)")
                if unfaded.pixel(column, row) != label { lines += 1 }
            }
        }
        #expect(lines > 10, "the fade-in of A draws in the chip: \(lines)")
    }

    /// A name with descenders stays in the chip: its lowest text pixel is above the chip bottom.
    @Test func aDescenderStaysInTheChip() throws {
        let inputs = try Self.inputs(path: "gp.wav")
        let pixels = try Self.render(inputs, .light)
        let (rows, columns) = (0..<Int(ClipLabel.height), 10..<16 + Int(ClipLabel.width(of: "gp")))
        let text = (0..<100).filter { row in columns.contains { pixels.pixel($0, row) == LanePalette.light.label } }
        let lowest = try #require(text.max(), "the label draws")
        #expect(lowest < rows.upperBound, "the lowest text row \(lowest) is above the chip bottom \(rows.upperBound)")
        #expect(rows.allSatisfy { row in columns.allSatisfy { pixels.pixel($0, row) != LanePalette.light.rms } })
    }
}
