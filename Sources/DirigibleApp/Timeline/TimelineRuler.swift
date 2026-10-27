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
    /// The current marker of the window (decision 0018): it draws with its own look.
    var current: MarkerID? {
        didSet { if current != oldValue { needsDisplay = true } }
    }
    /// The flag of a take marker that shows a highlight until `end` (F107). Tests give their own
    /// `now` and `reducesMotion`.
    private(set) var highlight: (marker: MarkerID, end: ContinuousClock.Instant)?
    var now: () -> ContinuousClock.Instant = { .now }
    var reducesMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private static let highlightTime = Duration.milliseconds(300)
    private var clearing: Task<Void, Never>?

    /// Lights the flag of `marker` for 0.3 s. With Reduce Motion on, it lights nothing.
    func highlight(_ marker: MarkerID) {
        guard !reducesMotion() else { return }
        highlight = (marker, now() + Self.highlightTime)
        needsDisplay = true
        clearing?.cancel()
        clearing = Task { [weak self] in
            try? await Task.sleep(for: Self.highlightTime)
            if !Task.isCancelled { self?.needsDisplay = true }
        }
    }

    func highlights(_ marker: MarkerID) -> Bool {
        guard let highlight, highlight.marker == marker else { return false }
        return now() < highlight.end
    }

    /// The draws and the rect of the last draw, for the ruler guard of a page turn (live take G5).
    private(set) var draws = 0
    private(set) var drawnRect = NSRect.zero
    /// The outline draws of a lit flag, for the tests of the highlight.
    private(set) var highlightDraws = 0
    /// The head of the playhead, a layer over the times.
    let head = PlayheadHead()

    init(model: SessionWindow) {
        self.model = model
        super.init(scrollView: nil, orientation: .horizontalRuler)
        ruleThickness = Self.thickness
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
        // macOS 14 does not clip a view by default: the base line drew past the lanes into the
        // inspector (run 11b-2, on-screen check).
        clipsToBounds = true
        wantsLayer = true
        layer?.addSublayer(head.container)
    }

    required init(coder: NSCoder) { fatalError("no coder") }

    /// The ruler x of a document x.
    private func x(of documentX: Double) -> Double {
        Double(convert(NSPoint(x: documentX, y: 0), from: scrollView?.documentView).x)
    }

    /// Puts the tip of the head at the document x `documentX`. The ruler x moves with the horizontal
    /// scroll, so the container starts at the ruler x of the left edge of the lanes in view.
    func moveHead(toDocumentX documentX: Double, taking: Bool) {
        guard let shown = (scrollView as? TimelineScrollView)?.shown else { return }
        head.place(
            at: x(of: documentX), edge: x(of: Double(shown.minX)), width: bounds.width, taking: taking,
            scale: Double(window?.backingScaleFactor ?? 2))
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
            let label = typeset(
                rulerLabel(seconds, tenths: step < 1), color: .secondaryLabelColor,
                font: .monospacedDigitSystemFont(ofSize: 10, weight: .regular))
            draw(label, at: NSPoint(x: at + 3, y: 2))
            seconds += step
        }
        // The current marker draws last, so its label is on top.
        let markers = inputs.markers.values.sorted {
            ($0.id == current ? 1 : 0, $0.position) < ($1.id == current ? 1 : 0, $1.position)
        }
        for marker in markers {
            let color: NSColor = marker.kind == .marker ? .systemOrange : .systemPurple
            let at = x(of: inputs.geometry.x(of: marker.position))
            let isCurrent = marker.id == current
            defer { if highlights(marker.id) { drawHighlight(of: marker, at: at, left: left) } }
            color.setFill()
            NSRect(x: at, y: 0, width: isCurrent ? 2 : 1, height: Self.thickness).fill()
            let box = RulerGeometry.flagReach.upperBound
            NSRect(x: at, y: 12, width: box, height: box).fill()
            // A marker name is user data: it shows as typed. The current marker shows its name in
            // semibold on a pill in the flag color: black on orange and white on purple, for contrast.
            let name = NSPoint(x: at + 8, y: 10)
            guard isCurrent else {
                draw(typeset(marker.name, color: color, font: .systemFont(ofSize: 10)), at: name)
                continue
            }
            let text = typeset(
                marker.name, color: marker.kind == .marker ? .black : .white,
                font: .systemFont(ofSize: 10, weight: .semibold))
            let width = CTLineGetTypographicBounds(text.line, nil, nil, nil)
            NSBezierPath(roundedRect: NSRect(x: at + 5, y: 9, width: width + 6, height: 14), xRadius: 3, yRadius: 3)
                .fill()
            draw(text, at: name)
        }
        triangle(inputs.marks.inPoint, inputs.geometry, .systemGreen)
        triangle(inputs.marks.outPoint, inputs.geometry, .systemRed)
    }

    /// A 2 pt outline in the label color around the flag and its name.
    private func drawHighlight(of marker: Marker, at x: Double, left: Double) {
        let text = typeset(marker.name, color: .black, font: .systemFont(ofSize: 10, weight: .semibold))
        let width = CTLineGetTypographicBounds(text.line, nil, nil, nil)
        let outline = NSBezierPath(
            roundedRect: Self.highlightRect(at: x, nameWidth: width, left: left), xRadius: 5, yRadius: 5)
        outline.lineWidth = Self.highlightLine
        NSColor.labelColor.setStroke()
        outline.stroke()
        highlightDraws += 1
    }

    static let highlightLine = 2.0

    /// The path of the outline of a lit flag at the ruler x `x` with a name `nameWidth` wide. It
    /// holds the flag box and the pill of the current marker, and its stroke ends at the ruler
    /// bottom, so the bottom edge meets the pill. The ruler draws only right of `left`, the left
    /// edge of the lanes, so the left stroke stops there and covers the edge of a flag box at it.
    static func highlightRect(at x: Double, nameWidth: Double, left: Double) -> NSRect {
        let maxX = x + nameWidth + 14
        let minX = min(max(x - 3, left + highlightLine / 2), maxX)
        return NSRect(x: minX, y: 7, width: maxX - minX, height: thickness - 7 - highlightLine / 2)
    }

    /// The typeset lines of the ruler text, by text, font, color, and appearance. A ripple drag
    /// moves every later flag, and the typesetting of the text was half of the ruler draw (run 12).
    private var lines: [String: (line: CTLine, ascent: CGFloat)] = [:]

    /// The typeset line of `text` in `font` and `color`, from the cache.
    private func typeset(_ text: String, color: NSColor, font: NSFont) -> (line: CTLine, ascent: CGFloat) {
        let key = "\(font.fontName)|\(color)|\(effectiveAppearance.name.rawValue)|\(text)"
        return lines[key]
            ?? {
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
    }

    /// Draws a typeset line with its top left at `point`, as `NSString.draw(at:)` places it in
    /// this flipped view.
    private func draw(_ typeset: (line: CTLine, ascent: CGFloat), at point: NSPoint) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
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
    /// field had the focus (plan gate 2 item 1). The typed text saves first, as at a lane
    /// mouse-down, so a marker draft keeps its marker. A double-click on a flag shows the Marker
    /// pane; the press still goes to the gesture, so a drag after it moves the flag (C9).
    override func mouseDown(with event: NSEvent) {
        guard let timeline, let place = place(event), overLanes(place) else { return }
        window?.makeFirstResponder(timeline.lanes)
        model?.commitDrafts()
        // Before the press: the target is nil during a gesture.
        var flag: MarkerID?
        if event.clickCount == 2, case .ruler(let x, _) = place { flag = timeline.menuTarget(at: x)?.marker }
        let flags = event.modifierFlags
        timeline.mouse(.down(place, shift: flags.contains(.shift), command: flags.contains(.command)))
        showCursor(event)
        if let flag, let model {
            model.timeline.marker = flag
            model.showMarkerInfo()
        }
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
    /// criterion 13). No menu during a gesture or over the track headers. The add items are off
    /// during a take, because they add at a clicked frame and a take marker goes to the record head.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let place = place(event), overLanes(place), case .ruler(let x, _) = place,
            let target = timeline?.menuTarget(at: x)
        else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let isOn = { (command: TimelineCommand) in self.model?.isOn(command) == true }
        let canEdit = model?.canEdit == true
        let items: [(L10n, Selector, Any, Bool)] = [
            (.menuMarkersAdd, #selector(addMarkerItem(_:)), target.frame.count, canEdit),
            (.menuMarkersAddChapter, #selector(addChapterItem(_:)), target.frame.count, canEdit),
            (
                .menuMarkersDelete, #selector(deleteMarkerItem(_:)), target.marker?.rawValue ?? "",
                target.marker != nil && isOn(.deleteMarker)
            ),
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
