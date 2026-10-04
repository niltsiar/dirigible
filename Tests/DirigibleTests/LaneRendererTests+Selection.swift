import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Multi-clip-selection C14 (decision 0038, `ui-panel.md` 3): each selected clip box draws a light
/// tint and a 2 pt outline in the accent color, by clip ID. At 256 frames per point and scale 1:
/// A is columns 0 ..< 100 and C is 100 ..< 200 on t1; B is 0 ..< 100 on t2. The set is {A, B}.
struct LaneRendererSelectionTests {
    static func session() throws -> Session {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f1", path: "f1.wav", layout: .mono, length: 51_200))
        try session.addFile(AudioFile(id: "f2", path: "f2.wav", layout: .mono, length: 51_200))
        try session.addTrack("t1", name: "T1", layout: .mono)
        try session.addTrack("t2", name: "T2", layout: .mono)
        try session.place(Clip(id: "A", file: "f1", start: 0, offset: 0, length: 25_600), on: "t1")
        try session.place(Clip(id: "C", file: "f1", start: 25_600, offset: 25_600, length: 25_600), on: "t1")
        try session.place(Clip(id: "B", file: "f2", start: 0, offset: 0, length: 25_600), on: "t2")
        return session
    }

    static func render(_ selection: Selection, _ palette: LanePalette) throws -> OwnedPixels {
        let bins = (0..<200).map { PeakColumn(peak: UInt16(200 * $0), rms: UInt16(100 * $0)) }
        var inputs = LaneRendererTests.inputs(try session(), peaks: bins)
        inputs.selection = selection
        let pixels = OwnedPixels(try #require(laneWindow(inputs, width: 220, scale: 1)))
        pixels.draw { LaneRenderer().draw(inputs, palette, into: $0) }
        return pixels
    }

    /// Control: a renderer that draws only the band leaves the boxes of the set as they were.
    @Test(arguments: [LanePalette.light, LanePalette.dark(accent: 0xFFFF_2D55)])
    func aClipSelectionTintsAndOutlinesEachSelectedBox(palette: LanePalette) throws {
        let plain = try Self.render(.none, palette)
        let picked = try Self.render(.clips(try #require(ClipSet(["A", "B"]))), palette)
        for lane in 0..<2 {
            let rows = lane * 100..<(lane + 1) * 100
            let edges = rows.allSatisfy { row in [0, 1, 98, 99].allSatisfy { picked.pixel($0, row) == palette.outline }
            }
            #expect(edges, "lane \(lane): the left and right 2 px are the outline, over the gain line")
            let topAndBottom = (0..<100).allSatisfy { column in
                [rows.lowerBound, rows.lowerBound + 1, rows.upperBound - 2, rows.upperBound - 1].allSatisfy {
                    picked.pixel(column, $0) == palette.outline
                }
            }
            #expect(topAndBottom, "lane \(lane): the top and bottom 2 px are the outline")
            let tinted = (2..<98).allSatisfy { column in
                (rows.lowerBound + 2..<rows.upperBound - 2).allSatisfy {
                    picked.pixel(column, $0) == palette.tinted(plain.pixel(column, $0))
                }
            }
            #expect(tinted, "lane \(lane): the inside is tinted")
        }
        let c = (100..<220).allSatisfy { column in
            (0..<100).allSatisfy { picked.pixel(column, $0) == plain.pixel(column, $0) }
        }
        #expect(c, "C is not in the set: no tint, no outline")
    }

    /// Code gate 1 item 3: the outline is the system accent in light mode too.
    @Test func theLightPaletteTakesTheAccent() throws {
        #expect(LanePalette.light(accent: 0xFFFF_2D55).outline == 0xFFFF_2D55)
        let accent = try #require(NSColor.controlAccentColor.usingColorSpace(.sRGB))
        let red = UInt32((accent.redComponent * 255).rounded())
        let picked = LanePalette.pick(for: try #require(NSAppearance(named: .aqua)))
        #expect((picked.outline >> 16) & 0xFF == red && picked.accent == nil, "the accent, and no band accent")
    }
}
