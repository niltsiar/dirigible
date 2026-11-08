import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp

/// The column mask of a region (C53, the still band of a ripple drag): a masked draw writes the
/// pixels of a full draw in the mask columns and no pixel outside them.
extension LaneRendererTests {
    @MainActor @Test func aMaskedDrawEqualsAFullDrawInTheMaskAndWritesNothingElse() throws {
        var session = Session(sampleRate: 48_000)
        for n in 1...2 {
            try session.addFile(AudioFile(id: FileID("f\(n)"), path: "f\(n).wav", layout: .mono, length: 400_000))
        }
        for n in 1...3 { try session.addTrack(TrackID("t\(n)"), name: "T\(n)", layout: .mono) }
        try session.place(
            Clip(id: "c1", file: "f1", start: 178_100, offset: 37, length: 9_000, gain: Gain(dB: -3)!), on: "t1")
        try session.place(Clip(id: "c2", file: "f1", start: 187_100, offset: 9_037, length: 4_000), on: "t1")
        try session.place(Clip(id: "c3", file: "f1", start: 180_000, offset: 500, length: 8_500), on: "t2")
        try session.setFades(["c3": Fades(fadeIn: 1_000, fadeOut: 2_000)!])
        var random = SplitMix(seed: 9)
        for n in 0..<20 {
            try session.place(
                Clip(
                    id: ClipID("r\(n)"), file: "f2", start: Frames(177_000 + n * 700 + Int(random.next() % 300)),
                    offset: Frames(Int(random.next() % 1000)), length: Frames(100 + Int(random.next() % 300))),
                on: "t3")
        }
        try session.setMarker(Marker(id: "m1", name: "M", position: 181_234, kind: .marker))
        try session.setMarker(Marker(id: "m2", name: "C", position: 185_000, kind: .chapter))
        let inputs = LaneInputs(
            session: session,
            peaks: ["f1": .ready(randomPeaks(frames: 400_000)), "f2": .ready(randomPeaks(frames: 400_000))],
            missingMedia: ["f2": .short(180_000)],
            selection: .range(Marks(inPoint: 179_001, outPoint: 186_777, tracks: ["t2"])),
            scale: TimelineScale(framesPerPoint: 133.37), laneHeight: 100)
        let window = try #require(laneWindow(inputs, x: 1333, width: 100, scale: 2))
        let rows = window.pixels.rows
        let sentinel: UInt32 = 0xFFAB_CDEF
        let full = OwnedPixels(window, fill: sentinel)
        full.draw { TimelineDocumentView.drawLanes(LaneRenderer(), inputs, .light, into: $0) }
        #expect(!rows.contains { full.row($0).contains(sentinel) }, "a full draw writes every pixel")
        // Unsorted, with an overlap, a touch, and a part past the rect.
        let parts = [
            2850..<2860, 2670..<2671, 2686..<2700, 2743..<2744, 2744..<2746, 2716..<2724, 2800..<2801, 2799..<2802,
            2900..<2910,
        ]
        let rect = PixelRect(columns: 2670..<2860, rows: rows)
        var chips: [Range<Int>] = []
        full.draw { region in chips = ClipLabel.labels(inputs, live: nil, in: region).map { $0.cut(scale: 2).columns } }
        #expect(
            chips.filter { chip in parts.contains { $0.overlaps(chip) } }.count == 2,
            "a part crosses the chips of c1 and c3: \(chips)")

        let masked = OwnedPixels(window, fill: sentinel)
        masked.draw(rect, mask: parts) { TimelineDocumentView.drawLanes(LaneRenderer(), inputs, .light, into: $0) }

        let inMask = Set(parts.flatMap { Array($0.clamped(to: rect.columns)) })
        var (differ, written) = ([Int](), [Int]())
        for row in rows {
            let (a, b) = (full.row(row), masked.row(row))
            for (index, column) in window.pixels.columns.enumerated() {
                if inMask.contains(column), a[index] != b[index] { differ.append(column) }
                if !inMask.contains(column), b[index] != sentinel { written.append(column) }
            }
        }
        #expect(
            differ.isEmpty, "\(differ.count) mask pixels differ from a full draw, the first at \(differ.first ?? 0)")
        #expect(written.isEmpty, "\(written.count) pixels outside the mask changed, the first at \(written.first ?? 0)")
    }
}
