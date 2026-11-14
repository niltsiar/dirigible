import AppKit
import DirigibleTimeline
import SwiftUI

/// The text that VoiceOver reads after a step of the waveform range: "Waveform range 72 dB". `text`
/// gives the value of a key.
func waveformAnnouncement(_ range: WaveformRange, text: (L10n) -> String = { $0.text }) -> String {
    String(format: text(.waveformZoomAnnounce), locale: .current, range.rawValue)
}

/// The range as the readout and the menu show it: "72 dB". `text` gives the value of a key.
func waveformRangeText(_ range: WaveformRange, text: (L10n) -> String = { $0.text }) -> String {
    String(format: text(.waveformZoomReadout), locale: .current, range.rawValue)
}

extension SessionWindow {
    /// The range of this window is not the app default: Reset is on, and the readout shows.
    var canResetWaveformRange: Bool { app.map { timeline.waveformRange != $0.waveformRangeDefault } == true }

    /// View > Waveform Zoom In, Waveform Zoom Out, and Reset Waveform Zoom. A step sets the range of
    /// this window and says it. A step that cannot go (an end of the ranges, or Reset at the app
    /// default) beeps and says nothing. A lane gesture keeps the lane rows of its preview until the
    /// mouse-up, so a step waits for it, as the height keys do.
    func zoomWaveform(_ command: TimelineCommand) {
        guard timelineView?.gesture.isActive != true else { return }
        let range = timeline.waveformRange
        let target: WaveformRange? =
            switch command {
            case .waveformZoomIn: range.zoomedIn
            case .waveformZoomOut: range.zoomedOut
            case .waveformZoomReset: app?.waveformRangeDefault == range ? nil : app?.waveformRangeDefault
            default: nil
            }
        guard let target else { return beep() }
        setWaveformRange(target)
    }

    /// Sets the range of this window only, redraws the lanes once, and says it.
    fileprivate func setWaveformRange(_ range: WaveformRange) {
        guard timelineView?.gesture.isActive != true, range != timeline.waveformRange else { return }
        timeline.waveformRange = range
        chrome?.announce(waveformAnnouncement(range), .high)
    }
}

/// The menu of a right-click or a Control-click on the scale strip or the readout: the ranges, with a
/// check on the range of the window, then Reset Waveform Zoom, off at the app default. It is its own
/// target, so the menu keeps the actions alive while it shows.
final class WaveformRangeMenu: NSMenu {
    private weak var model: SessionWindow?

    @MainActor init(model: SessionWindow) {
        self.model = model
        super.init(title: "")
        autoenablesItems = false
        for range in WaveformRange.allCases {
            let item = NSMenuItem(title: waveformRangeText(range), action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.tag = range.rawValue
            item.state = range == model.timeline.waveformRange ? .on : .off
            addItem(item)
        }
        addItem(.separator())
        let reset = NSMenuItem(
            title: L10n.menuViewWaveformZoomReset.text, action: #selector(reset(_:)), keyEquivalent: "")
        reset.target = self
        reset.isEnabled = model.canResetWaveformRange
        addItem(reset)
    }

    required init(coder: NSCoder) { fatalError("no coder") }

    @MainActor @objc private func choose(_ item: NSMenuItem) {
        if let range = WaveformRange(rawValue: item.tag) { model?.setWaveformRange(range) }
    }

    @MainActor @objc private func reset(_ item: NSMenuItem) { model?.zoomWaveform(.waveformZoomReset) }
}

/// The range text in the ruler band over the track headers while the range of the window is not the
/// app default. It is one button: a click resets, a right-click or a Control-click shows the menu.
struct WaveformReadout: View {
    /// The width of its slot at the trailing end of the band, in points.
    static let slot = 52.0

    let model: SessionWindow

    var body: some View {
        if model.canResetWaveformRange {
            WaveformReadoutButton(model: model, range: model.timeline.waveformRange)
                .frame(width: Self.slot, height: TimelineRuler.thickness)
        }
    }
}

private struct WaveformReadoutButton: NSViewRepresentable {
    let model: SessionWindow
    let range: WaveformRange

    func makeNSView(context: Context) -> ReadoutView {
        let view = ReadoutView()
        view.model = model
        return view
    }

    func updateNSView(_ view: ReadoutView, context: Context) { view.show(range) }
}

/// The button of the readout.
final class ReadoutView: NSButton {
    weak var model: SessionWindow?
    private var range: WaveformRange?

    init() {
        super.init(frame: .zero)
        isBordered = false
        target = self
        action = #selector(click)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(displayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { nil }

    /// The text color: `secondaryLabelColor`, and `labelColor` with Increase Contrast.
    static func color(increasesContrast: Bool) -> NSColor { increasesContrast ? .labelColor : .secondaryLabelColor }

    func show(_ range: WaveformRange) {
        guard range != self.range else { return }
        self.range = range
        paint()
        setAccessibilityLabel(waveformAnnouncement(range))
    }

    @objc private func displayOptionsChanged() { paint() }

    /// The slot gives the size, not the text.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    private func paint() {
        guard let range else { return }
        let color = Self.color(increasesContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
        attributedTitle = NSAttributedString(
            string: waveformRangeText(range),
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: color])
    }

    @objc private func click() { model?.zoomWaveform(.waveformZoomReset) }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityChildren() -> [Any]? { [] }

    override func accessibilityPerformPress() -> Bool {
        click()
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? { model.map(WaveformRangeMenu.init) }

    /// Shows `menu` under the button. The app pops it up; a test records it.
    var present: (NSMenu, NSView) -> Void = {
        $0.popUp(positioning: nil, at: NSPoint(x: 0, y: $1.bounds.height), in: $1)
    }

    override func accessibilityPerformShowMenu() -> Bool {
        guard let menu = model.map(WaveformRangeMenu.init) else { return false }
        present(menu, self)
        return true
    }
}
