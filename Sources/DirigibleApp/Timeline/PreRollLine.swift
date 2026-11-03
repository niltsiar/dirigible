import AppKit

/// The red line at T during the pre-roll of a take (decision 0070, **Window**): a layer over the
/// lanes like the snap guide, so it never changes a lane pixel. It writes a layer property only when
/// its place changes.
final class PreRollLine: CALayer {
    private var placed: (x: Double, width: Double, height: Double)?

    override init() {
        super.init()
        // Under the playhead (10).
        zPosition = 9
        isHidden = true
    }

    override init(layer: Any) { super.init(layer: layer) }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// No implicit animation.
    override func action(forKey event: String) -> (any CAAction)? { nil }

    /// Shows the line at the document x `x`, `width` points wide and `height` high; nil hides it.
    func show(at x: Double?, width: Double, height: Double, appearance: NSAppearance) {
        guard let x else {
            placed = nil
            if !isHidden { isHidden = true }
            return
        }
        guard placed?.x != x || placed?.width != width || placed?.height != height || isHidden else { return }
        placed = (x, width, height)
        appearance.performAsCurrentDrawingAppearance { backgroundColor = NSColor.systemRed.cgColor }
        bounds = CGRect(x: 0, y: 0, width: width, height: height)
        position = CGPoint(x: x, y: height / 2)
        isHidden = false
    }
}
