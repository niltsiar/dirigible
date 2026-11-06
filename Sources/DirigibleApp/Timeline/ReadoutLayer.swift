import AppKit
import DirigibleCore
import DirigibleTimeline

/// The value of a gain, fade-handle, or crossfade-handle drag next to the pointer (run 11b-1): a text layer over the
/// lanes, so it never changes a lane pixel and needs no lane redraw (decision 0020). A gain readout
/// also shows a bar from -20 dB to +20 dB with a 0 dB tick and a marker at the gain: over 0 dB the
/// gain line stays on the lane top, so only the marker shows the change (ui-polish C24).
final class ReadoutLayer: CATextLayer {
    let bar = CALayer()
    let tick = CALayer()
    let marker = CALayer()

    override init() {
        super.init()
        font = Self.font()
        fontSize = 11
        alignmentMode = .center
        cornerRadius = 4
        borderWidth = 0.5
        isHidden = true
        for layer in [bar, tick, marker] {
            layer.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull(), "backgroundColor": NSNull()]
            addSublayer(layer)
        }
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
            bar.backgroundColor = NSColor.separatorColor.cgColor
            tick.backgroundColor = NSColor.secondaryLabelColor.cgColor
            marker.backgroundColor = NSColor.controlAccentColor.cgColor
        }
        contentsScale = view.window?.backingScaleFactor ?? 2
        string = text
        let size = NSAttributedString(string: text, attributes: [.font: Self.font()]).size()
        var (width, height) = ((size.width + 12).rounded(.up), (size.height + 4).rounded(.up))
        let gain: Gain? = if case .gain(let gain, _) = readout { gain } else { nil }
        for layer in [bar, tick, marker] { layer.isHidden = gain == nil }
        if let gain {
            // The bar is at least 80 pt, so 1 dB is at least 2 pt.
            width = max(width, 92)
            let barWidth = width - 12
            bar.frame = NSRect(x: 6, y: height + 2, width: barWidth, height: 2)
            tick.frame = NSRect(x: 6 + barWidth / 2 - 0.5, y: height, width: 1, height: 6)
            marker.frame = NSRect(x: 6 + Self.markerX(gain, barWidth: barWidth) - 1, y: height - 1, width: 2, height: 8)
            height += 10
        }
        // The lanes are flipped: above the pointer is a lower y. With no room above, it goes below.
        let above = point.y - 12 - height
        let x = min(max(point.x + 12, visible.minX), visible.maxX - width)
        let y = min(max(above >= visible.minY ? above : point.y + 12, visible.minY), visible.maxY - height)
        frame = NSRect(x: x, y: y, width: width, height: height)
        isHidden = false
    }

    static func font() -> NSFont { .monospacedDigitSystemFont(ofSize: 11, weight: .regular) }

    /// The x of the marker of `gain` on a bar of `barWidth`: -20 dB at 0, +20 dB at the end
    /// (`Gain.levelLimit`). A gain outside the limits stops at the end.
    static func markerX(_ gain: Gain, barWidth: Double) -> Double {
        (min(max(gain.dB, -Gain.levelLimit), Gain.levelLimit) + Gain.levelLimit) / (2 * Gain.levelLimit) * barWidth
    }

    /// The text of `readout`: the gain in dB to 0.1 and its change since the mouse-down, or the fade
    /// or crossfade length, or the signed move of a roll or slip, in whole ms at `rate`, or the gain of a
    /// point or of a range gain in dB, in the number format of `locale`. `value` gives the string of a
    /// key (a test passes a table).
    static func text(_ readout: GestureReadout, rate: Int, locale: Locale, value: (L10n) -> String) -> String {
        switch readout {
        case .gain(let gain, let start):
            return String(
                format: value(.timelineReadoutGain), decibels(gain.dB, locale: locale),
                decibels(gain.dB - start.dB, locale: locale))
        case .fade(let edge, let length):
            let key: L10n = edge == .start ? .timelineReadoutFadeIn : .timelineReadoutFadeOut
            return String(format: value(key), milliseconds(length, rate: rate, locale: locale))
        case .crossfade(let length):
            return String(format: value(.timelineReadoutCrossfade), milliseconds(length, rate: rate, locale: locale))
        case .point(let gain):
            return String(format: value(.timelineReadoutPoint), decibels(gain.dB, locale: locale))
        case .rangeGain(let gain):
            return String(format: value(.timelineReadoutRangeGain), decibels(gain.dB, locale: locale))
        case .roll(let move):
            return String(
                format: value(.timelineReadoutRoll), milliseconds(move, rate: rate, locale: locale, signed: true))
        case .slip(let move):
            return String(
                format: value(.timelineReadoutSlip), milliseconds(move, rate: rate, locale: locale, signed: true))
        }
    }

    /// A length in whole ms at `rate`: "460". With `signed`, a move: "+500", "-500", "0".
    static func milliseconds(_ length: Frames, rate: Int, locale: Locale, signed: Bool = false) -> String {
        // Adding 0 turns the -0 of a small negative move into 0.
        let ms = (Double(length.count) * 1000 / Double(rate)).rounded() + 0
        return ms.formatted(
            .number.precision(.fractionLength(0)).sign(strategy: signed ? .always(includingZero: false) : .automatic)
                .locale(locale))
    }

    /// A gain or a gain change in dB to 0.1, with its sign: "-6.0", "+4.0", "0.0" (in Spanish "-6,0").
    static func decibels(_ dB: Double, locale: Locale) -> String {
        dB.formatted(
            .number.precision(.fractionLength(1)).sign(strategy: .always(includingZero: false)).locale(locale))
    }
}
