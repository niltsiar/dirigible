import AppKit

/// The snap guide (snap run, decision 0020): a yellow line over the lanes at the target of a snap.
/// It is a layer like the playhead, so it never changes a lane pixel. Each change from hidden to
/// shown plays the alignment haptic once (a Force Touch trackpad only).
final class GuideLayer: CALayer {
    /// The haptic of a snap; a test counts the calls.
    var feedback: @MainActor () -> Void = {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    override init() {
        super.init()
        backgroundColor = NSColor.systemYellow.cgColor
        // Above the playhead (10), under the readout (20).
        zPosition = 11
        isHidden = true
    }

    override init(layer: Any) { super.init(layer: layer) }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// No implicit animation: the line follows the drag.
    override func action(forKey event: String) -> (any CAAction)? { nil }

    /// Shows the line at the document x `x`, `width` points wide and `height` high; nil hides it.
    @MainActor func show(at x: Double?, width: Double, height: Double) {
        guard let x else {
            isHidden = true
            return
        }
        if isHidden { feedback() }
        bounds = CGRect(x: 0, y: 0, width: width, height: height)
        position = CGPoint(x: x, y: height / 2)
        isHidden = false
    }
}
