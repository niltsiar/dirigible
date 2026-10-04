import AppKit
import DirigibleCore
import DirigibleTimeline

/// Every input that the ruler draws. The ruler redraws only when it changes.
struct RulerInputs: Equatable {
    var markers: [MarkerID: Marker]
    var marks: Marks
    var geometry: LaneGeometry
    var rate: Int
}

/// The time ruler over the lanes (decision 0017): time labels whose step follows the zoom, marker
/// flags (orange) and chapter flags (purple) with their names, and the in (green) and out (red)
/// triangles, drawn with the constants of `RulerGeometry` (decision 0020). Its mouse events go to
/// the gesture of the scroll view: a flag drag moves a marker, a triangle drag moves the in or out
/// point, and a click in the time area seeks. A right-click gives the ruler menu.
final class TimelineRuler: NSRulerView {
    static let thickness = CGFloat(RulerGeometry.thickness)
    weak var model: SessionWindow?
    var inputs: RulerInputs? {
        didSet { if inputs != oldValue { needsDisplay = true } }
    }
    /// The draws and the rect of the last draw, for the ruler guard of a page turn (live take G5).
    private(set) var draws = 0
    private(set) var drawnRect = NSRect.zero

    init(model: SessionWindow) {
        self.model = model
        super.init(scrollView: nil, orientation: .horizontalRuler)
        ruleThickness = Self.thickness
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
        // macOS 14 does not clip a view by default: the base line drew past the lanes into the
        // inspector (run 11b-2, on-screen check).
        clipsToBounds = true
    }

    required init(coder: NSCoder) { fatalError("no coder") }

    /// The ruler x of a document x.
    private func x(of documentX: Double) -> Double {
        Double(convert(NSPoint(x: documentX, y: 0), from: scrollView?.documentView).x)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let inputs, let visible = (scrollView as? TimelineScrollView)?.shown else { return }
        (draws, drawnRect) = (draws + 1, rect)
        // The ruler is as wide as the window, also over the track headers. It draws only over the
        // lanes in view, so the times under the headers do not show there (timeline-scroll symptom 2).
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let left = x(of: Double(visible.minX))
        NSRect(x: left, y: bounds.minY, width: max(0, bounds.maxX - left), height: bounds.height).clip()
        let points = inputs.geometry.scale.framesPerPoint
        let rate = Double(max(1, inputs.rate))
        // A label every 80 pt or more.
        let steps: [Double] = [0.1, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]
        let step = steps.first { $0 * rate / points >= 80 } ?? 7200
        let first = (Double(visible.minX) * points / rate / step).rounded(.down) * step
        var seconds = first
        NSColor.separatorColor.setFill()
        while seconds * rate / points <= Double(visible.maxX) {
            let at = x(of: seconds * rate / points)
            NSRect(x: at, y: Self.thickness - 6, width: 1, height: 6).fill()
            draw(
                rulerLabel(seconds, tenths: step < 1), at: NSPoint(x: at + 3, y: 2), color: .secondaryLabelColor,
                digits: true)
            seconds += step
        }
        for marker in inputs.markers.values.sorted(by: { $0.position < $1.position }) {
            let color: NSColor = marker.kind == .marker ? .systemOrange : .systemPurple
            let at = x(of: inputs.geometry.x(of: marker.position))
            color.setFill()
            NSRect(x: at, y: 0, width: 1, height: Self.thickness).fill()
            let box = RulerGeometry.flagReach.upperBound
            NSRect(x: at, y: 12, width: box, height: box).fill()
            // A marker name is user data: it shows as typed.
            draw(marker.name, at: NSPoint(x: at + 8, y: 10), color: color, digits: false)
        }
        triangle(inputs.marks.inPoint, inputs.geometry, .systemGreen)
        triangle(inputs.marks.outPoint, inputs.geometry, .systemRed)
    }

    /// The typeset lines of the ruler text, by text, font, color, and appearance. A ripple drag
    /// moves every later flag, and the typesetting of the text was half of the ruler draw (run 12).
    private var lines: [String: (line: CTLine, ascent: CGFloat)] = [:]

    /// Draws `text` with its top left at `point`, in the 10 pt system font (monospaced digits for
    /// the time labels), as `NSString.draw(at:)` places it in this flipped view.
    private func draw(_ text: String, at point: NSPoint, color: NSColor, digits: Bool) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let key = "\(digits)|\(color)|\(effectiveAppearance.name.rawValue)|\(text)"
        let typeset =
            lines[key]
            ?? {
                let font =
                    digits ? NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular) : .systemFont(ofSize: 10)
                var cgColor = color.cgColor
                effectiveAppearance.performAsCurrentDrawingAppearance { cgColor = color.cgColor }
                let string = NSAttributedString(
                    string: text,
                    attributes: [
                        .font: font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): cgColor,
                    ])
                if lines.count > 1_000 { lines.removeAll() }
                let made = (CTLineCreateWithAttributedString(string), font.ascender)
                lines[key] = made
                return made
            }()
        context.saveGState()
        defer { context.restoreGState() }
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: point.x, y: point.y + typeset.ascent)
        CTLineDraw(typeset.line, context)
    }

    private func triangle(_ frame: Frames?, _ geometry: LaneGeometry, _ color: NSColor) {
        guard let frame else { return }
        let at = x(of: geometry.x(of: frame))
        let (half, band) = (RulerGeometry.triangleHalfWidth, RulerGeometry.triangleBand)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: at - half, y: band.lowerBound))
        path.line(to: NSPoint(x: at + half, y: band.lowerBound))
        path.line(to: NSPoint(x: at, y: band.upperBound))
        path.close()
        color.setFill()
        path.fill()
    }

    // MARK: Mouse

    private var timeline: TimelineScrollView? { scrollView as? TimelineScrollView }

    /// The document x and the ruler y of an event.
    private func place(_ event: NSEvent) -> Place? {
        guard let timeline else { return nil }
        let x = Double(timeline.lanes.convert(event.locationInWindow, from: nil).x)
        return .ruler(x: x, y: Double(convert(event.locationInWindow, from: nil).y))
    }

    /// True for a place over the lanes in view. The part of the ruler over the track headers shows
    /// no time, so a press or a menu there does nothing; a drag that started over the lanes goes on.
    private func overLanes(_ place: Place) -> Bool {
        guard case .ruler(let x, _) = place, let shown = timeline?.shown else { return false }
        return x >= Double(shown.minX)
    }

    /// The lanes become the first responder, so Esc reaches the gesture also when a track name
    /// field had the focus (plan gate 2 item 1).
    override func mouseDown(with event: NSEvent) {
        guard let timeline, let place = place(event), overLanes(place) else { return }
        window?.makeFirstResponder(timeline.lanes)
        let flags = event.modifierFlags
        timeline.mouse(.down(place, shift: flags.contains(.shift), command: flags.contains(.command)))
        showCursor(event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let place = place(event) else { return }
        timeline?.mouse(.drag(place))
        timeline?.dragPointer = (event.locationInWindow, ruler: true)
        showCursor(event)
    }

    override func mouseUp(with event: NSEvent) {
        guard let place = place(event) else { return }
        timeline?.mouse(.up(place))
        showCursor(event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard trackingAreas.isEmpty else { return }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { hoverCursor(event) }
    override func cursorUpdate(with event: NSEvent) { hoverCursor(event) }

    /// The arrow over the track headers, else the cursor of the gesture.
    private func hoverCursor(_ event: NSEvent) {
        guard let place = place(event), overLanes(place) else { return NSCursor.arrow.set() }
        showCursor(event)
    }

    private func showCursor(_ event: NSEvent) {
        guard let place = place(event), let kind = timeline?.cursor(at: place) else { return }
        NSCursor.timeline(kind).set()
    }

    // MARK: Menu

    /// Add Marker and Add Chapter at the clicked frame, and Delete Marker on a flag (mouse-edits
    /// criterion 13). No menu during a gesture or over the track headers.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let place = place(event), overLanes(place), case .ruler(let x, _) = place,
            let target = timeline?.menuTarget(at: x)
        else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let items: [(L10n, Selector, Any, Bool)] = [
            (.menuMarkersAdd, #selector(addMarkerItem(_:)), target.frame.count, true),
            (.menuMarkersAddChapter, #selector(addChapterItem(_:)), target.frame.count, true),
            (.menuMarkersDelete, #selector(deleteMarkerItem(_:)), target.marker?.rawValue ?? "", target.marker != nil),
        ]
        for (title, action, object, enabled) in items {
            let item = NSMenuItem(title: title.text, action: action, keyEquivalent: "")
            (item.target, item.representedObject, item.isEnabled) = (self, object, enabled)
            menu.addItem(item)
        }
        return menu
    }

    @objc private func addMarkerItem(_ item: NSMenuItem) {
        guard let frame = item.representedObject as? Int else { return }
        model?.addMarker(.marker, at: Frames(frame))
    }

    @objc private func addChapterItem(_ item: NSMenuItem) {
        guard let frame = item.representedObject as? Int else { return }
        model?.addMarker(.chapter, at: Frames(frame))
    }

    /// Delete Marker makes the flag the current marker, then deletes it as the Markers menu does.
    @objc private func deleteMarkerItem(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String, let model else { return }
        model.timeline.marker = MarkerID(id)
        model.run(.deleteMarker)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }
}

/// A ruler label: m:ss, or h:mm:ss after an hour, with tenths when the step is under 1 s.
func rulerLabel(_ seconds: Double, tenths: Bool) -> String {
    let tenthsCount = Int((seconds * 10).rounded())
    let whole = tenthsCount / 10
    let (hours, minutes, rest) = (whole / 3600, whole / 60 % 60, whole % 60)
    var text =
        hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    if tenths { text += ".\(tenthsCount % 10)" }
    return text
}
