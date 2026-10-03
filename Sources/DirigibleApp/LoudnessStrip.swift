import AppKit
import DirigibleAudio
import QuartzCore
import SwiftUI

/// The texts that the loudness strip shows (decision 0033).
struct LoudnessTexts: Equatable {
    var shortTerm = LoudnessText.dash
    var integrated = LoudnessText.dash
    /// The measured time of the integrated value; empty with no value.
    var duration = ""
    var peak = LoudnessText.dash
    /// The true peak is over -1 dBTP: the text is red.
    var peakOver = false
    var target = ""
}

/// The formats of the loudness values. The strip only formats: `Studio.loudness` gives nil M and
/// S when no 1x forward play runs.
enum LoudnessText {
    static let dash = "\u{2013}"
    /// A true peak over this value turns the Peak text red (dBTP).
    static let peakLimit = -1.0

    /// One decimal: "-17.4". Nil gives an en dash.
    static func value(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? dash }

    /// m:ss, and h:mm:ss from 1 h.
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let (hours, minutes, rest) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }

    static func texts(_ values: LoudnessValues, target: LUFS) -> LoudnessTexts {
        LoudnessTexts(
            shortTerm: value(values.shortTerm?.value), integrated: value(values.integrated?.value),
            duration: values.integrated == nil ? "" : duration(values.seconds), peak: value(values.truePeak),
            peakOver: (values.truePeak ?? -.infinity) > peakLimit, target: String(format: "%.0f", target.value))
    }

    /// The short-term value of a track header in whole LU ("-17"), only while the track records
    /// or monitors.
    static func header(_ live: LiveTrack) -> String? {
        guard live.state == .recording || live.state == .monitoring, let lufs = live.shortTerm else { return nil }
        return String(format: "%.0f", lufs.value)
    }
}

/// The line of the strip for the stored token of the export preset: its stereo target; with Off,
/// the podcast target. The meter measures the stereo mix, so a mono export at -19 equals this line
/// (decision 0033).
func loudnessTarget(_ token: String?) -> LUFS {
    (ExportSettings.loudness(token: token) ?? .podcast).integrated(for: .stereo)
}

/// The loudness strip below the lanes (decision 0033): an opaque row of 28 pt. The display tick
/// calls `show`. The bar is layers that move only on a pixel change; the texts are drawn and
/// change at most 4 times a second, the VoiceOver value at most once a second.
final class LoudnessStrip: NSView, NSViewToolTipOwner {
    static let height: CGFloat = 28
    static let textInterval: CFTimeInterval = 0.25
    static let accessibilityInterval: CFTimeInterval = 1

    /// The texts on screen, and the counts of the tests.
    private(set) var texts = LoudnessTexts()
    private(set) var textChanges = 0
    private(set) var layerChanges = 0
    private(set) var accessibilityChanges = 0
    private var accessibilityText = ""
    /// The inputs of the last `show`. A call with the same inputs and nothing pending does nothing.
    private var shown: Shown?
    /// A text or a VoiceOver value that its rate limit held back.
    private var pending = false
    private var inputs = false
    private var lastText = -CFTimeInterval.infinity
    private var lastAccessibility = -CFTimeInterval.infinity
    private var momentary: Double?
    private var target = LoudnessTarget.podcast.integrated(for: .stereo).value
    private var geometry = Geometry()
    private let track = CALayer()
    private let green = CALayer()
    private let yellow = CALayer()
    private let line = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        track.cornerRadius = 3
        track.masksToBounds = true
        track.addSublayer(green)
        track.addSublayer(yellow)
        layer?.addSublayer(track)
        layer?.addSublayer(line)
        texts.target = String(format: "%.0f", target)
        colors()
    }

    required init?(coder: NSCoder) { nil }

    override var isOpaque: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }

    private struct Shown: Equatable {
        let values: LoudnessValues
        let token: String?
        let inputs: Bool
    }

    /// Takes the values of the heard frame and the stored token of the export target. `inputs`:
    /// the armed tracks meter their inputs (a take or a monitor). `now` is a test seam.
    func show(
        _ values: LoudnessValues, target token: String?, inputs: Bool, now: CFTimeInterval = CACurrentMediaTime()
    ) {
        let input = Shown(values: values, token: token, inputs: inputs)
        guard input != shown || pending else { return }
        (shown, self.inputs) = (input, inputs)
        let target = loudnessTarget(token)
        let next = LoudnessText.texts(values, target: target)
        if next != texts, now - lastText >= Self.textInterval {
            let relayout = next.duration.count != texts.duration.count
            (texts, lastText) = (next, now)
            textChanges += 1
            needsDisplay = true
            if relayout { needsLayout = true }
        }
        if values.momentary?.value != momentary || target.value != self.target {
            (momentary, self.target) = (values.momentary?.value, target.value)
            placeBar()
        }
        let spoken = inputs ? L10n.loudnessTakeTip.text : spokenText
        if spoken != accessibilityText, now - lastAccessibility >= Self.accessibilityInterval {
            (accessibilityText, lastAccessibility) = (spoken, now)
            accessibilityChanges += 1
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
        pending = next != texts || spoken != accessibilityText
    }

    private var spokenText: String {
        [
            (L10n.loudnessShort, texts.shortTerm), (.loudnessAverage, texts.integrated), (.loudnessPeak, texts.peak),
            (.loudnessTarget, texts.target),
        ].map { "\($0.text) \($1)" }.joined(separator: ", ")
    }

    // MARK: Layout and drawing

    private static let labelFont = NSFont.systemFont(ofSize: 11)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
    private static let spanFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private static let inset: CGFloat = 12
    private static let gap: CGFloat = 20
    private static let baseline: CGFloat = 9

    /// One cell: a label, a value slot as wide as its template, and an optional span.
    private struct Cell {
        let label: L10n
        let template: String
        var x: CGFloat = 0
        var labelWidth: CGFloat = 0
        var valueWidth: CGFloat = 0
        var spanWidth: CGFloat = 0
        var width: CGFloat { labelWidth + 6 + valueWidth + (spanWidth > 0 ? 5 + spanWidth : 0) }
    }

    private struct Geometry {
        var cells: [Cell] = []
        var bar = CGRect.zero
    }

    private static func width(_ text: String, _ font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
    }

    override func layout() {
        super.layout()
        var cells = [
            Cell(label: .loudnessShort, template: "-00.0"), Cell(label: .loudnessAverage, template: "-00.0"),
            Cell(label: .loudnessPeak, template: "-00.0"), Cell(label: .loudnessTarget, template: "-00"),
        ]
        for index in cells.indices {
            cells[index].labelWidth = Self.width(cells[index].label.text, Self.labelFont)
            cells[index].valueWidth = Self.width(cells[index].template, Self.valueFont)
        }
        // The span slot keeps its width while its digit count stays.
        let span = texts.duration.replacingOccurrences(of: "[0-9]", with: "0", options: .regularExpression)
        cells[1].spanWidth = span.isEmpty ? 0 : Self.width(span, Self.spanFont)
        cells[0].x = Self.inset
        var x = bounds.width - Self.inset
        for index in cells.indices.dropFirst().reversed() {
            x -= cells[index].width
            cells[index].x = x
            x -= Self.gap
        }
        let barX = cells[0].x + cells[0].width + 14
        let bar = CGRect(x: barX, y: 11, width: max(0, min(360, x + Self.gap - 14 - barX)), height: 6)
        geometry = Geometry(cells: cells, bar: bar)
        removeAllToolTips()
        addToolTip(bounds, owner: self, userData: nil)
        placeBar()
        needsDisplay = true
    }

    /// Sets the bar layers, with no animation, only when a frame changes by a device pixel.
    private func placeBar() {
        let bar = geometry.bar
        func position(_ lufs: Double) -> CGFloat { bar.width * CGFloat(min(max((lufs + 40) / 40, 0), 1)) }
        let level = momentary.map(position) ?? 0
        let mark = position(target)
        let frames = [
            bar, CGRect(x: 0, y: 0, width: min(level, mark), height: bar.height),
            CGRect(x: mark, y: 0, width: max(0, level - mark), height: bar.height),
            CGRect(x: bar.minX + mark - 1, y: bar.minY - 4, width: 2, height: bar.height + 8),
        ].map { backingAlignedRect($0, options: .alignAllEdgesNearest) }
        let layers = [track, green, yellow, line]
        guard zip(layers, frames).contains(where: { $0.frame != $1 }) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (layer, frame) in zip(layers, frames) { layer.frame = frame }
        CATransaction.commit()
        layerChanges += 1
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        colors()
    }

    private func colors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            track.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            green.backgroundColor = NSColor.systemGreen.cgColor
            yellow.backgroundColor = NSColor.systemYellow.cgColor
            line.backgroundColor = NSColor.labelColor.cgColor
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        let values = [texts.shortTerm, texts.integrated, texts.peak, texts.target]
        for (index, cell) in geometry.cells.enumerated() {
            let red = index == 2 && texts.peakOver
            draw(cell.label.text, at: cell.x, Self.labelFont, .secondaryLabelColor)
            // The value ends at the end of its slot, so the digits stay in place.
            let value = values[index]
            let valueX = cell.x + cell.labelWidth + 6 + cell.valueWidth - Self.width(value, Self.valueFont)
            draw(value, at: valueX, Self.valueFont, red ? .systemRed : .labelColor)
            if index == 1, !texts.duration.isEmpty {
                draw(
                    texts.duration, at: cell.x + cell.labelWidth + 6 + cell.valueWidth + 5, Self.spanFont,
                    .secondaryLabelColor)
            }
        }
    }

    /// All text sits on one baseline.
    private func draw(_ text: String, at x: CGFloat, _ font: NSFont, _ color: NSColor) {
        (text as NSString).draw(
            at: NSPoint(x: x, y: Self.baseline + font.descender),
            withAttributes: [.font: font, .foregroundColor: color])
    }

    // MARK: Tooltips and VoiceOver

    func view(
        _ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?
    ) -> String {
        toolTip(at: point)
    }

    /// The tooltip of the cell at `point`; the EBU names are here, not on the strip.
    func toolTip(at point: NSPoint) -> String {
        let cells = geometry.cells
        if inputs || cells.isEmpty { return inputs ? L10n.loudnessTakeTip.text : L10n.loudnessShortTip.text }
        if point.x < geometry.bar.minX - 7 { return L10n.loudnessShortTip.text }
        if point.x < cells[1].x - Self.gap / 2 { return L10n.loudnessMomentaryTip.text }
        if point.x < cells[2].x - Self.gap / 2 { return L10n.loudnessAverageTip.text }
        if point.x < cells[3].x - Self.gap / 2 { return L10n.loudnessPeakTip.text }
        return L10n.loudnessTargetTip.text
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .levelIndicator }
    override func accessibilityLabel() -> String? { L10n.loudnessMeter.text }
    override func accessibilityValue() -> Any? { accessibilityText }
}

/// The strip in the SwiftUI content of the window. It hands the view to the window model, which
/// the display tick reads.
struct LoudnessStripView: NSViewRepresentable {
    let model: SessionWindow

    func makeNSView(context: Context) -> LoudnessStrip {
        let strip = LoudnessStrip(frame: .zero)
        model.loudnessStrip = strip
        return strip
    }

    func updateNSView(_ strip: LoudnessStrip, context: Context) {}
}

extension SessionWindow {
    /// The app preference of View > Show Loudness Meter: a `Bool`, default true. It never
    /// changes its meaning or type (0024 P11).
    static let loudnessKey = "view.loudness.shown"

    /// View > Show/Hide Loudness Meter. A new window takes the preference.
    func toggleLoudness() {
        showsLoudness.toggle()
        app?.defaults?.set(showsLoudness, forKey: Self.loudnessKey)
    }

    /// One display tick of the strip, when it shows. During a take or a monitor the armed tracks
    /// meter their inputs, so the strip shows dashes, not the held values of a play.
    func loudnessTick(_ studio: Studio) {
        guard let strip = loudnessStrip, strip.window != nil else { return }
        let inputs = !studio.liveTracks.isEmpty
        strip.show(
            inputs ? .none : studio.loudness, target: app?.defaults?.string(forKey: ExportSettings.loudnessKey),
            inputs: inputs)
    }
}

extension AppDelegate {
    /// The title and the state of View > Show/Hide Loudness Meter for the key window.
    var loudnessItem: (title: L10n, enabled: Bool) { loudnessItem(for: key) }

    func loudnessItem(for model: SessionWindow?) -> (title: L10n, enabled: Bool) {
        (model?.showsLoudness == true ? .menuViewLoudnessHide : .menuViewLoudnessShow, model != nil)
    }
}
