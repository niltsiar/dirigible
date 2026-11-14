import AppKit
import DirigibleTimeline

/// What the strip draws with. It draws again only when one of these changes, so a play tick and a
/// header drag draw nothing.
struct ScaleStripInputs: Equatable {
    var range: WaveformRange
    var laneHeight: Double
    var lanes: Int
}

/// The dB scale at the trailing edge of the track headers, beside each lane (decision 0017). It is
/// a subview of `TrackHeaderRuler`, so the header rows keep their width. A tick sits where a
/// 0 dBFS signal of that level ends in the lane, by the formula of the waveform. The header handle
/// covers its trailing 6 pt and gives it a right-click and a Control-click.
final class WaveformScaleStrip: NSView {
    /// The width in points.
    static let width = 20.0
    /// The levels that get a tick, with -R dB.
    static let levels = [0.0, -6, -12, -24]
    /// The lane height from which the ticks have labels.
    static let labelsFrom = 48.0
    private static let tick = 4.0
    private static let labelFont = NSFont.systemFont(ofSize: 8)
    private static let labelHeight = 9.0

    /// The draws, for the tests.
    private(set) var draws = 0
    /// The document y at the top of the clip view: the strip keeps the position of the lanes.
    var top = 0.0 {
        didSet { if top != oldValue { needsDisplay = true } }
    }
    var inputs: ScaleStripInputs? {
        didSet { if inputs != oldValue { needsDisplay = true } }
    }
    /// Shows `menu` for a Control-click. The app pops it up; a test records it.
    var present: (NSMenu, NSEvent, NSView) -> Void = { NSMenu.popUpContextMenu($0, with: $1, for: $2) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(displayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    @objc private func displayOptionsChanged() { needsDisplay = true }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    /// The ticks of one lane, from its top: the level in dB and the y in points. -24 dB and -R dB
    /// are one tick when equal; a level under -R dB has no tick.
    static func ticks(range: WaveformRange, laneHeight: Double) -> [(dB: Double, y: Double)] {
        var levels = Self.levels.filter { -$0 <= range.dB }
        if !levels.contains(-range.dB) { levels.append(-range.dB) }
        // The lane height times 1 - fraction(dB:). The product comes first, so a whole dB gives an
        // exact y, as the gain line does.
        return levels.map { ($0, laneHeight * -$0 / range.dB) }
    }

    /// The ticks that carry a label in a lane: none under `labelsFrom`; from the top, a tick whose
    /// label would touch the one above does not show it. -R dB keeps its label at the lane bottom.
    static func labelled(range: WaveformRange, laneHeight: Double) -> [(dB: Double, y: Double)] {
        guard laneHeight >= labelsFrom else { return [] }
        var shown: [(dB: Double, y: Double)] = []
        for tick in ticks(range: range, laneHeight: laneHeight) {
            let last = tick.dB == -range.dB
            if let above = shown.last, tick.y - above.y < labelHeight {
                if last { shown.removeLast() } else { continue }
            }
            shown.append(tick)
        }
        return shown
    }

    override func draw(_ dirtyRect: NSRect) {
        // The ruler asks its subviews to draw the strip of its own exposed rect, which is not ours.
        guard dirtyRect.intersects(bounds) else { return }
        draws += 1
        guard let inputs else { return }
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let color = contrast ? NSColor.labelColor : NSColor.secondaryLabelColor
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.labelFont, .foregroundColor: color]
        let ticks = Self.ticks(range: inputs.range, laneHeight: inputs.laneHeight)
        let labels = Self.labelled(range: inputs.range, laneHeight: inputs.laneHeight)
        let first = max(0, Int(((top + dirtyRect.minY) / inputs.laneHeight).rounded(.down)))
        let last = min(inputs.lanes - 1, Int(((top + dirtyRect.maxY) / inputs.laneHeight).rounded(.down)))
        guard first <= last else { return }
        color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        for lane in first...last {
            let origin = Double(lane) * inputs.laneHeight - top
            for tick in ticks {
                // A tick at the lane top or bottom sits inside the lane: its line covers one pixel row.
                let y = min(max(origin + tick.y, origin + 0.5), origin + inputs.laneHeight - 0.5)
                path.move(to: NSPoint(x: bounds.maxX - 1 - Self.tick, y: y))
                path.line(to: NSPoint(x: bounds.maxX - 1, y: y))
            }
            for label in labels {
                let text = NSAttributedString(string: String(Int(label.dB)), attributes: attributes)
                let size = text.size()
                let y = min(
                    max(origin + label.y - size.height / 2, origin), origin + inputs.laneHeight - size.height)
                text.draw(at: NSPoint(x: bounds.maxX - 1 - Self.tick - 1 - size.width, y: y))
            }
        }
        path.stroke()
    }

    // MARK: Mouse

    private var model: SessionWindow? {
        ((superview as? TrackHeaderRuler)?.scrollView as? TimelineScrollView)?.model
    }

    override func menu(for event: NSEvent) -> NSMenu? { model.map(WaveformRangeMenu.init) }

    /// A double click resets the range, and does nothing at the app default. A Control-click shows
    /// the menu. The strip is no drag target.
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            showMenu(event)
        } else if event.clickCount == 2, let model, model.canResetWaveformRange {
            model.zoomWaveform(.waveformZoomReset)
        }
    }

    func showMenu(_ event: NSEvent) {
        if let menu = menu(for: event) { present(menu, event, self) }
    }
}
