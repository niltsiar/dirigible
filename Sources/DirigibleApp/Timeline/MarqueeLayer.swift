import AppKit

/// The marquee of a Shift-drag (decision 0038): a rectangle over the lanes, with an accent border (1 pt,
/// 2 pt under Increase Contrast) and an accent fill. It is a layer like the guide, so it never changes a lane pixel.
final class MarqueeLayer: CALayer {
    override init() {
        super.init()
        // Above the guide (11), under the readout (20).
        zPosition = 12
        isHidden = true
    }

    override init(layer: Any) { super.init(layer: layer) }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// No implicit animation: the rectangle follows the pointer.
    override func action(forKey event: String) -> (any CAAction)? { nil }

    /// Shows the rectangle at `rect` in document points with a border `width` points wide; nil hides
    /// it. The caller sets the drawing appearance, so the accent color resolves for the light and the
    /// dark appearance.
    @MainActor func show(_ rect: NSRect?, width: Double) {
        guard let rect else {
            isHidden = true
            return
        }
        if isHidden {
            borderColor = NSColor.controlAccentColor.cgColor
            backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
        }
        borderWidth = width
        frame = rect
        isHidden = false
    }
}
