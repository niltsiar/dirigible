import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleTimeline

/// A label of a lane draw: the clip name, or the take label of the live region. One draw builds
/// the labels once: the renderer leaves the chip free of peak and RMS spans, so the box fill shows
/// there, and the label pass draws the text on it (run 2026-10-11-ui-polish-header C14). The chip
/// is at the top of the box, in the clip bar, between the fade handles of its clip.
struct ClipLabel {
    /// Nil for the take label.
    let clip: ClipID?
    let lane: Int
    let text: String
    /// The parts of the box where the label draws: an old clip label shows only outside the live
    /// region.
    let shown: [NSRect]
    /// At the top of the box, between the fade handles, in document points. Empty when no room is
    /// left for it.
    let chip: NSRect
    let origin: NSPoint
    /// The squares of the envelope discs that meet the chip: the text leaves them free.
    let holes: [NSRect]

    /// A computed value: an `NSFont` is not `Sendable`.
    static var font: NSFont { .systemFont(ofSize: 11, weight: .medium) }
    /// The chip height: the line of the font, so a descender stays on the chip.
    static let height: Double = {
        let font = ClipLabel.font
        return (font.ascender - font.descender + font.leading).rounded(.up) + 1
    }()
    /// The bar under the chip: 1 pt higher, so the chip lies in it.
    static let barHeight = height + 1

    /// The distance of the chip from the box start when the start handle is at rest (points).
    static let inset = LaneGeometry.handleSize + 2

    /// The one width rule of the chip and the bar (points).
    static func hasChip(width: Double) -> Bool { width >= 60 }

    /// Whether a clip box has a bar: a box with a chip, in a lane of 60 pt or taller.
    static func hasBar(width: Double, laneHeight: Double) -> Bool { laneHeight >= 60 && hasChip(width: width) }

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

    /// The chip starts at `start` and ends at `end` at the latest, which are `inset` from the box start
    /// and the box end when no fade handle of the clip moves them. `discs` are the squares of the
    /// envelope discs of the clip.
    @MainActor init(
        clip: ClipID?, lane: Int, text: String, box: NSRect, shown: [NSRect], start: Double? = nil,
        end: Double? = nil, discs: [NSRect] = []
    ) {
        let (start, end) = (start ?? box.minX + Self.inset, end ?? box.maxX)
        let width = min(Self.width(of: text) + 6, end - start)
        (self.clip, self.lane, self.text, self.shown) = (clip, lane, text, shown)
        let chip = width > 0 ? NSRect(x: start, y: box.minY, width: width, height: Self.height) : .zero
        (self.chip, origin) = (chip, NSPoint(x: start + 3, y: box.minY))
        // Discs 8 pt apart have squares that overlap: they make one hole, as an even-odd clip needs.
        var holes: [NSRect] = []
        for disc in discs {
            let hole = disc.intersection(chip)
            guard !hole.isNull, !hole.isEmpty else { continue }
            if let last = holes.last, last.maxX > hole.minX {
                holes[holes.count - 1] = last.union(hole)
            } else {
                holes.append(hole)
            }
        }
        self.holes = holes
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
                guard hasChip(width: box.width), box.intersects(rect) else { continue }
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
                // The chip lies between the fade handles and leaves the envelope discs free.
                let index = track.clips.index(holding: clip.start)
                let handles = index.map { geometry.fadeHandles(of: clip, at: $0, in: track.clips, lane: lane) }
                let reach = LaneGeometry.pointRadius + 1.5
                let discs =
                    index.map {
                        geometry.envelopePoints(of: clip, at: $0, in: track.clips, trackGain: track.gain, lane: lane)
                            .map { NSRect(x: $0.x - reach, y: $0.y - reach, width: 2 * reach, height: 2 * reach) }
                    } ?? []
                labels.append(
                    ClipLabel(
                        clip: clip.id, lane: lane, text: text, box: box, shown: shown,
                        start: (handles?.start).map { max($0.maxX + 2, box.minX + inset) },
                        end: (handles?.end).map { $0.minX - 2 }, discs: discs))
            }
            if let region, let live, region.intersects(rect) {
                labels.append(ClipLabel(clip: nil, lane: lane, text: live.label, box: region, shown: [region]))
            }
        }
        return labels
    }

    /// The pixel columns of the chip and the row under its bottom, for `LaneRenderer.drawColumns`.
    func cut(scale: Double) -> (columns: Range<Int>, bottom: Int) {
        guard !chip.isEmpty else { return (0..<0, 0) }
        let columns = Int((chip.minX * scale).rounded(.down))..<Int((chip.maxX * scale).rounded(.up))
        return (columns, Int((chip.maxY * scale).rounded(.up)))
    }
}
