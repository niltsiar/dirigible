import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleTimeline

/// The clip labels of the lanes, apart from the lane draw.
extension TimelineDocumentView {
    /// The clip label: its file path without `.wav` (Release 1 clips have no name), at the bottom
    /// left of the box, cut at the box end. It reads only the clips in the frames of the rect of
    /// `region`, lane by lane, and draws only in that rect. A box under 60 pt gets no label: 12,000
    /// labels at fit zoom took 330 ms per draw (probe L1, decision 0020). The live region of a take
    /// gets the take label at each width, cut at the box end, and an old clip label shows only
    /// outside it. So a column of the take label does not change when the box grows, and the
    /// partial draw of a tick gives the pixels of a full draw.
    static func drawLabels(
        _ inputs: LaneInputs, _ palette: LanePalette, live: LiveLanes.Take? = nil, into region: borrowing PixelRegion
    ) {
        guard inputs.laneHeight > 14, let geometry = inputs.geometry, !region.rect.isEmpty else { return }
        let rect = region.window.points(of: region.rect)
        let frames = geometry.frame(at: rect.minX)..<geometry.frame(at: rect.maxX) + Frames(2)
        let regions = live?.boxes(inputs, scale: region.window.scale) ?? [:]
        var labels: [(box: NSRect, shown: [NSRect], name: String)] = []
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
                labels.append((box, shown, Self.labelText(name, gain: clip.gain, locale: .current)))
            }
            if let region, let live, region.intersects(rect) {
                labels.append((region, [region], live.label))
            }
        }
        guard !labels.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10), .foregroundColor: palette.labelColor,
        ]
        region.withContext { context in
            let previous = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            defer { NSGraphicsContext.current = previous }
            for (box, shown, name) in labels {
                // Only in its box: the dirty rect of a drag event holds the boxes it changes.
                context.saveGState()
                context.clip(to: shown)
                name.draw(at: NSPoint(x: box.minX + 4, y: box.maxY - 14), withAttributes: attributes)
                context.restoreGState()
            }
        }
    }

    /// The label of a clip: its name, and its gain when it is not 0 ("take1-1  -6.0 dB").
    nonisolated static func labelText(_ name: String, gain: Gain, locale: Locale) -> String {
        gain == .zero ? name : "\(name)  \(ReadoutLayer.decibels(gain.dB, locale: locale)) dB"
    }
}
