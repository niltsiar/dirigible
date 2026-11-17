import AppKit
import DirigibleCore
import SwiftUI

/// The Amount slider of the match popover (decision 0074, UI council ruling 4): 1 to 100 percent.
/// A drag plays its value at once with no edit, and the mouse-up makes one edit, as the track
/// fader does (`TrackFader`). The drag value stays in this view.
struct MatchAmountSlider: NSViewRepresentable {
    let model: SessionWindow
    let track: TrackID
    let percent: Int

    func makeNSView(context: Context) -> MatchAmountView { MatchAmountView() }

    func updateNSView(_ view: MatchAmountView, context: Context) {
        view.update(model: model, track: track, percent: percent, enabled: context.environment.isEnabled)
    }
}

/// The slider and the percent readout of `MatchAmountSlider`, side by side.
final class MatchAmountView: NSView {
    /// The room of the widest readout, "100 %" (`TrackFaderView.readoutWidth` is the same idea).
    static let readoutWidth = 44.0
    static let size = NSSize(width: 120 + 4 + readoutWidth, height: 18)
    let slider = MatchSlider(value: 75, minValue: 1, maxValue: 100, target: nil, action: nil)
    let readout = NSTextField(labelWithString: "")

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        slider.controlSize = .small
        slider.isContinuous = true
        slider.target = slider
        slider.action = #selector(MatchSlider.moved)
        slider.readout = readout
        slider.frame = NSRect(x: 0, y: 0, width: 120, height: Self.size.height)
        readout.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        readout.textColor = .secondaryLabelColor
        readout.alignment = .right
        readout.frame = NSRect(x: 124, y: 2, width: Self.readoutWidth, height: 14)
        readout.setAccessibilityElement(false)
        addSubview(slider)
        addSubview(readout)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("MatchAmountView has no coder") }

    override var intrinsicContentSize: NSSize { Self.size }

    /// The session value of the track. During a drag the slider and the readout keep the drag value.
    func update(model: SessionWindow, track: TrackID, percent: Int, enabled: Bool) {
        slider.model = model
        slider.track = track
        slider.stored = percent
        slider.isEnabled = enabled
        if !slider.dragging { slider.show(percent) }
    }
}

/// The slider of `MatchAmountView`. Its value is a whole percent.
final class MatchSlider: NSSlider {
    weak var model: SessionWindow?
    var track: TrackID = ""
    /// The session amount of the track.
    var stored = 75
    weak var readout: NSTextField?
    private(set) var dragging = false
    /// The last value of a drag, the session revision, and the time of the last mouse-up that made an
    /// edit.
    private var shown = 75
    private var clickEdit: (revision: Int, time: TimeInterval)?

    /// `NSCell` tracks the drag in a modal loop and returns at the mouse-up, so the drag is the
    /// call of `super.mouseDown`. A double-click or an Option-click sets the default amount.
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return super.mouseDown(with: event) }
        if event.clickCount >= 2 || event.modifierFlags.contains(.option) {
            // The first click of a double-click off the thumb moved the thumb there and made an
            // edit. The reset joins that edit, so a double-click is one undo step.
            if event.clickCount >= 2, let click = clickEdit,
                event.timestamp - click.time < NSEvent.doubleClickInterval
            {
                model?.resetMatchAmount(track, joining: click.revision)
            } else {
                model?.resetMatchAmount(track, joining: -1)
            }
            clickEdit = nil
            return
        }
        (dragging, shown) = (true, stored)
        defer { endDrag() }
        super.mouseDown(with: event)
    }

    /// The wheel scrolls the popover and never changes the amount.
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }

    /// A drag that ends at the start value makes no edit and gives the Player the session amount.
    private func endDrag() {
        dragging = false
        let edited = model?.commitMatchAmount(shown, track: track) ?? false
        clickEdit = edited ? model?.studio.map { ($0.sessionRevision, ProcessInfo.processInfo.systemUptime) } : nil
        show(shown)
    }

    /// A drag step plays its value with no edit. A change outside a drag (a key or VoiceOver) is one edit.
    @objc func moved() {
        let percent = integerValue
        showReadout(percent)
        guard dragging else {
            model?.commitMatchAmount(percent, track: track)
            return
        }
        guard percent != shown else { return }
        shown = percent
        model?.previewMatchAmount(percent, track: track)
    }

    func show(_ percent: Int) {
        shown = percent
        integerValue = percent
        showReadout(percent)
    }

    private func showReadout(_ percent: Int) {
        readout?.stringValue = VoiceMatch.Amount.text(percent)
    }

    override func accessibilityLabel() -> String? { L10n.trackMatchAmount.text }

    override func accessibilityValueDescription() -> String? { VoiceMatch.Amount.text(shown) }
}
