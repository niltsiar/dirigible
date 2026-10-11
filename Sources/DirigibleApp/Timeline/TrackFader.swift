import AppKit
import DirigibleCore
import DirigibleTimeline
import SwiftUI

/// The volume fader of a header row (F94, decision 0039): a mini slider on the scale of
/// `FaderScale` and a dB readout. A drag plays its value at once with no edit, and the mouse-up
/// makes one edit. The drag value stays in this view: a drag step writes no state that a row
/// reads, so no row body runs (C11).
struct TrackFader: NSViewRepresentable {
    let model: SessionWindow
    let track: TrackID
    let name: String
    let dB: Double

    func makeNSView(context: Context) -> TrackFaderView { TrackFaderView() }

    func updateNSView(_ view: TrackFaderView, context: Context) {
        view.update(model: model, track: track, name: name, dB: dB, enabled: context.environment.isEnabled)
    }
}

/// The slider and the readout of `TrackFader`, side by side: 80 pt and `readoutWidth`.
final class TrackFaderView: NSView {
    /// The room of the widest readout, "-96.0 dB" (`TrackFaderTests.theReadoutInEachLanguage`).
    static let readoutWidth = 56.0
    static let size = NSSize(width: 84 + readoutWidth, height: 16)
    let slider = FaderSlider(value: 0.75, minValue: 0, maxValue: 1, target: nil, action: nil)
    let readout = NSTextField(labelWithString: "")

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        slider.controlSize = .mini
        slider.isContinuous = true
        // Gray, not the accent color: R, Monitor, M, and S have the colors (ui-panel synthesis).
        // The slider blends the fill into the track: system gray draws near black in Light Mode,
        // but does not show in Dark Mode, so Dark Mode takes white (on-screen check of S5).
        slider.trackFillColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .white : .systemGray
        }
        slider.refusesFirstResponder = true
        slider.toolTip = L10n.trackVolumeHelp.text
        slider.target = slider
        slider.action = #selector(FaderSlider.moved)
        slider.readout = readout
        slider.frame = NSRect(x: 0, y: 0, width: 80, height: 16)
        readout.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        readout.alignment = .right
        readout.frame = NSRect(x: 84, y: 1, width: Self.readoutWidth, height: 14)
        readout.setAccessibilityElement(false)
        addSubview(slider)
        addSubview(readout)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("TrackFaderView has no coder") }

    override var intrinsicContentSize: NSSize { Self.size }

    /// The session value of the row. During a drag the slider and the readout keep the drag value.
    func update(model: SessionWindow, track: TrackID, name: String, dB: Double, enabled: Bool) {
        slider.model = model
        slider.track = track
        slider.name = name
        slider.stored = dB
        slider.isEnabled = enabled
        if !slider.dragging { slider.show(dB) }
    }

    /// The readout text of `dB`: "-6.0 dB", in the number format of `locale`.
    static func readout(_ dB: Double, locale: Locale, value: (L10n) -> String) -> String {
        String(format: value(.trackVolumeValue), ReadoutLayer.decibels(dB, locale: locale))
    }
}

/// The slider of `TrackFaderView`. Its value is a position from 0 to 1 on `FaderScale`.
final class FaderSlider: NSSlider {
    weak var model: SessionWindow?
    var track: TrackID = ""
    var name = ""
    /// The session gain of the track.
    var stored = 0.0
    weak var readout: NSTextField?
    /// The gain that the readout shows: the drag value during a drag, else the session gain.
    private(set) var shown = 0.0
    /// The scale from the drag start and the last drag value, between `beginDrag` and `endDrag`.
    private var drag: (scale: FaderScale, dB: Double)?
    var dragging: Bool { drag != nil }
    /// The session revision and the time of the last mouse-up that made an edit.
    private var clickEdit: (revision: Int, time: TimeInterval)?

    /// `NSCell` tracks the drag in a modal loop and returns at the mouse-up, so the drag is the
    /// call of `super.mouseDown`. A double-click or an Option-click sets 0 dB.
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return super.mouseDown(with: event) }
        if event.clickCount >= 2 || event.modifierFlags.contains(.option) {
            // The first click of a double-click off the thumb moved the thumb there and made an
            // edit. The reset joins that edit, so a double-click is one undo step (C8).
            if event.clickCount >= 2, let click = clickEdit,
                event.timestamp - click.time < NSEvent.doubleClickInterval
            {
                model?.resetVolume(track, joining: click.revision)
            } else {
                set(.zero)
            }
            clickEdit = nil
            return
        }
        beginDrag()
        defer { endDrag() }
        super.mouseDown(with: event)
    }

    /// The wheel scrolls the view and never changes the gain.
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    func beginDrag() {
        drag = (FaderScale(start: stored), stored)
    }

    /// A drag that ends at the start value makes no edit and gives the Player the session gain.
    func endDrag() {
        guard let drag else { return }
        self.drag = nil
        let edited = model?.commitVolume(drag.dB, track: track) ?? false
        clickEdit = edited ? model?.studio.map { ($0.sessionRevision, ProcessInfo.processInfo.systemUptime) } : nil
        show(drag.dB)
    }

    /// A drag step plays its value with no edit. An action outside a drag puts the thumb back.
    @objc func moved() {
        guard var drag else { return show(stored) }
        let dB = drag.scale.dB(position: doubleValue)
        guard dB != drag.dB else { return }
        drag.dB = dB
        self.drag = drag
        showReadout(dB)
        model?.previewVolume(dB, track: track)
    }

    /// The thumb and the readout at `dB`. A value outside the travel pins the thumb at its end.
    func show(_ dB: Double) {
        doubleValue = FaderScale(start: dB).position(dB: dB)
        showReadout(dB)
    }

    /// The readout is tertiary at 0.0 dB, so a changed track reads at a glance.
    private func showReadout(_ dB: Double) {
        shown = dB
        readout?.stringValue = Self.text(dB)
        readout?.textColor = dB == 0 ? .tertiaryLabelColor : .secondaryLabelColor
    }

    private static func text(_ dB: Double) -> String {
        TrackFaderView.readout(dB, locale: .current) { $0.text }
    }

    private func set(_ gain: Gain) {
        model?.setVolume(gain, tracks: [track])
    }

    // VoiceOver acts on the fader track only, never on the selection, and never beeps.

    override func accessibilityLabel() -> String? { L10n.trackVolumeLabel.format(name) }

    override func accessibilityValueDescription() -> String? { Self.text(shown) }

    override func accessibilityPerformIncrement() -> Bool {
        model?.stepVolume(by: 1, tracks: [track])
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        model?.stepVolume(by: -1, tracks: [track])
        return true
    }

    override func setAccessibilityValue(_ accessibilityValue: Any?) {
        guard let position = (accessibilityValue as? NSNumber)?.doubleValue,
            let gain = Gain(dB: FaderScale(start: stored).dB(position: position))
        else { return }
        set(gain)
    }
}
