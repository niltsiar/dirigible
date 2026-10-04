import AppKit
import DirigibleCore
import DirigibleTimeline

/// The value of a gain, fade-handle, or crossfade-handle drag next to the pointer (run 11b-1): a text layer over the
/// lanes, so it never changes a lane pixel and needs no lane redraw (decision 0020).
final class ReadoutLayer: CATextLayer {
    override init() {
        super.init()
        font = Self.font()
        fontSize = 11
        alignmentMode = .center
        cornerRadius = 4
        borderWidth = 0.5
        isHidden = true
    }

    override init(layer: Any) { super.init(layer: layer) }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// No implicit animation: the layer follows the pointer.
    override func action(forKey event: String) -> (any CAAction)? { nil }

    /// Shows `readout` 12 pt right of and 12 pt above `point` (below it at the top of `visible`),
    /// kept inside `visible`; nil hides it.
    @MainActor func show(_ readout: GestureReadout?, at point: NSPoint, in visible: NSRect, rate: Int, view: NSView) {
        guard let readout else {
            isHidden = true
            return
        }
        let text = Self.text(readout, rate: rate, locale: .current) { $0.text }
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            foregroundColor = NSColor.labelColor.cgColor
            backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95).cgColor
            borderColor = NSColor.separatorColor.cgColor
        }
        contentsScale = view.window?.backingScaleFactor ?? 2
        string = text
        let size = NSAttributedString(string: text, attributes: [.font: Self.font()]).size()
        let (width, height) = ((size.width + 12).rounded(.up), (size.height + 4).rounded(.up))
        // The lanes are flipped: above the pointer is a lower y. With no room above, it goes below.
        let above = point.y - 12 - height
        let x = min(max(point.x + 12, visible.minX), visible.maxX - width)
        let y = min(max(above >= visible.minY ? above : point.y + 12, visible.minY), visible.maxY - height)
        frame = NSRect(x: x, y: y, width: width, height: height)
        isHidden = false
    }

    static func font() -> NSFont { .monospacedDigitSystemFont(ofSize: 11, weight: .regular) }

    /// The text of `readout`: the gain in dB to 0.1, or the fade or crossfade length in whole ms at `rate`, in
    /// the number format of `locale`. `value` gives the string of a key (a test passes a table).
    static func text(_ readout: GestureReadout, rate: Int, locale: Locale, value: (L10n) -> String) -> String {
        switch readout {
        case .gain(let gain):
            return String(format: value(.timelineReadoutGain), decibels(gain, locale: locale))
        case .fade(let edge, let length):
            let key: L10n = edge == .start ? .timelineReadoutFadeIn : .timelineReadoutFadeOut
            return String(format: value(key), milliseconds(length, rate: rate, locale: locale))
        case .crossfade(let length):
            return String(format: value(.timelineReadoutCrossfade), milliseconds(length, rate: rate, locale: locale))
        }
    }

    /// A length in whole ms at `rate`: "460".
    static func milliseconds(_ length: Frames, rate: Int, locale: Locale) -> String {
        (Double(length.count) * 1000 / Double(rate)).rounded()
            .formatted(.number.precision(.fractionLength(0)).locale(locale))
    }

    /// A gain to 0.1 dB with its sign: "-6.0", "+4.0", "0.0" (in Spanish "-6,0").
    static func decibels(_ gain: Gain, locale: Locale) -> String {
        gain.dB.formatted(
            .number.precision(.fractionLength(1)).sign(strategy: .always(includingZero: false)).locale(locale))
    }
}
