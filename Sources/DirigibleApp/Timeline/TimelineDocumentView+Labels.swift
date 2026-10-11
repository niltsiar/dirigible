import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleTimeline

/// The clip labels of the lanes, apart from the lane draw.
extension TimelineDocumentView {
    /// The lanes in the rect of `region`, as the view draws them: the labels once, the lane pixels
    /// with a chip for each label, then the label texts.
    static func drawLanes(
        _ renderer: LaneRenderer, _ inputs: LaneInputs, _ palette: LanePalette, live: LiveLanes = LiveLanes(),
        into region: borrowing PixelRegion
    ) {
        let labels = ClipLabel.labels(inputs, live: live.take, in: region)
        renderer.draw(inputs, palette, live: live, labels: labels, into: region)
        drawLabels(labels, palette, into: region)
    }

    /// The clip label: its file path without `.wav` (Release 1 clips have no name), on its chip at
    /// the bottom left of the box, cut at the box end. It draws only in the rect of `region`.
    static func drawLabels(_ labels: [ClipLabel], _ palette: LanePalette, into region: borrowing PixelRegion) {
        guard !labels.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: ClipLabel.font, .foregroundColor: palette.labelColor]
        region.withContext { context in
            let previous = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            defer { NSGraphicsContext.current = previous }
            for label in labels {
                // Only in its box: the dirty rect of a drag event holds the boxes it changes.
                context.saveGState()
                context.clip(to: label.shown)
                label.text.draw(at: label.origin, withAttributes: attributes)
                context.restoreGState()
            }
        }
    }

    /// The label of a clip: its name, and its gain when it is not 0 ("take1-1  -6.0 dB").
    nonisolated static func labelText(_ name: String, gain: Gain, locale: Locale) -> String {
        gain == .zero ? name : "\(name)  \(ReadoutLayer.decibels(gain.dB, locale: locale)) dB"
    }
}
