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
    /// the top left of the box, in the bar, between the fade handles. It draws only in the rect of
    /// `region`.
    static func drawLabels(_ labels: [ClipLabel], _ palette: LanePalette, into region: borrowing PixelRegion) {
        guard !labels.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: ClipLabel.font, .foregroundColor: palette.labelColor]
        let previous = NSGraphicsContext.current
        defer { NSGraphicsContext.current = previous }
        region.withContext(in: labels.map(\.chip)) { context, index in
            if NSGraphicsContext.current?.cgContext !== context {
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            }
            let label = labels[index]
            // Only in its box: the dirty rect of a drag event holds the boxes it changes. And only
            // in its chip, with a hole at each envelope disc.
            context.clip(to: label.shown)
            let chip = CGMutablePath()
            chip.addRect(label.chip)
            chip.addRects(label.holes)
            context.addPath(chip)
            context.clip(using: .evenOdd)
            label.text.draw(at: label.origin, withAttributes: attributes)
        }
    }

    /// The label of a clip: its name, and its gain when it is not 0 ("take1-1  -6.0 dB").
    nonisolated static func labelText(_ name: String, gain: Gain, locale: Locale) -> String {
        gain == .zero ? name : "\(name)  \(ReadoutLayer.decibels(gain.dB, locale: locale)) dB"
    }
}
