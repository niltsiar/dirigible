import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleTimeline

/// A label of a lane draw: the clip name, or the take label of the live region. One draw builds
/// the labels once: the renderer leaves the chip free of peak and RMS spans, so the box fill shows
/// there, and the label pass draws the text on it (run 2026-10-11-ui-polish-header C14).
struct ClipLabel {
    /// Nil for the take label.
    let clip: ClipID?
    let lane: Int
    let text: String
    /// The parts of the box where the label draws: an old clip label shows only outside the live
    /// region.
    let shown: [NSRect]
    /// At the bottom-left of the box, cut at the box end, in document points.
    let chip: NSRect
    let origin: NSPoint

    /// A computed value: an `NSFont` is not `Sendable`.
    static var font: NSFont { .systemFont(ofSize: 11, weight: .medium) }
    /// The chip height: the line of the font, so a descender stays on the chip.
    static let height: Double = {
        let font = ClipLabel.font
        return (font.ascender - font.descender + font.leading).rounded(.up) + 1
    }()

    /// The text widths of the earlier draws. A measure at each draw made a Command-F event at
    /// 60 pt boxes 3 to 4 ms slower than main (decisions.tsv of the run, S5 row).
    @MainActor private static var widths: [String: Double] = [:]

    @MainActor static func width(of text: String) -> Double {
        if let width = widths[text] { return width }
        // A bound: the names of a long session do not stay in memory.
        if widths.count >= 4096 { widths.removeAll(keepingCapacity: true) }
        let width = (text as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
        widths[text] = width
        return width
    }

    @MainActor init(clip: ClipID?, lane: Int, text: String, box: NSRect, shown: [NSRect]) {
        let width = Self.width(of: text)
        let chip = NSRect(x: box.minX + 2, y: box.maxY - Self.height, width: width + 6, height: Self.height)
        (self.clip, self.lane, self.text, self.shown) = (clip, lane, text, shown)
        self.chip = chip.intersection(box)
        origin = NSPoint(x: chip.minX + 3, y: chip.minY)
    }

    /// The labels of the rect of `region`. It reads only the clips in the frames of the rect, lane
    /// by lane. A box under 60 pt gets no label: 12,000 labels at fit zoom took 330 ms per draw
    /// (probe L1, decision 0020). The live region of a take gets the take label at each width, cut
    /// at the box end, and an old clip label shows only outside it. So a column of the take label
    /// does not change when the box grows, and the partial draw of a tick gives the pixels of a
    /// full draw.
    @MainActor static func labels(_ inputs: LaneInputs, live: LiveLanes.Take?, in region: borrowing PixelRegion)
        -> [ClipLabel]
    {
        guard inputs.laneHeight > 14, let geometry = inputs.geometry, !region.rect.isEmpty else { return [] }
        let rect = region.window.points(of: region.rect)
        let frames = geometry.frame(at: rect.minX)..<geometry.frame(at: rect.maxX) + Frames(2)
        let regions = live?.boxes(inputs, scale: region.window.scale) ?? [:]
        var labels: [ClipLabel] = []
        for (lane, track) in inputs.session.tracks.enumerated() {
            let region = regions[lane]
            for clip in track.clips.clips(overlapping: frames) {
                let box = NSRect(geometry.box(of: clip, lane: lane))
                guard box.width >= 60, box.intersects(rect) else { continue }
                // The parts of the box on each side of the live region.
                let shown =
                    region.map { live in
                        let left = box.divided(atDistance: max(0, live.minX - box.minX), from: .minXEdge).slice
                        let right = box.divided(atDistance: max(0, box.maxX - live.maxX), from: .maxXEdge).slice
                        return [left, right].filter { $0.width > 0 }
                    } ?? [box]
                guard !shown.isEmpty else { continue }
                let name = ClipInspection.name(of: clip, in: inputs.session)
                let text = TimelineDocumentView.labelText(name, gain: clip.gain, locale: .current)
                labels.append(ClipLabel(clip: clip.id, lane: lane, text: text, box: box, shown: shown))
            }
            if let region, let live, region.intersects(rect) {
                labels.append(ClipLabel(clip: nil, lane: lane, text: live.label, box: region, shown: [region]))
            }
        }
        return labels
    }

    /// The pixel columns of the chip and its top row, for `LaneRenderer.drawColumns`.
    func cut(scale: Double) -> (columns: Range<Int>, top: Int) {
        // A chip outside its box (a box of a few points) is the null rect, with infinite edges.
        guard !chip.isEmpty else { return (0..<0, 0) }
        let columns = Int((chip.minX * scale).rounded(.down))..<Int((chip.maxX * scale).rounded(.up))
        return (columns, Int((chip.minY * scale).rounded(.down)))
    }
}
