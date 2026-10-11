import AppKit
import DirigibleCore
import DirigibleTimeline

/// The timeline pane: the overview strip at the top (decision 0025) and the lanes scroll view
/// under it. It only lays out.
final class TimelinePaneView: NSView {
    let overview = OverviewStrip()
    let scroll: TimelineScrollView

    init(scroll: TimelineScrollView) {
        self.scroll = scroll
        super.init(frame: .zero)
        addSubview(overview)
        addSubview(scroll)
        scroll.overview = overview
        overview.scrollView = scroll
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    /// The strip first: the tile of the scroll view places the view frame on the new strip width.
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        let strip = OverviewGeometry.height
        overview.frame = NSRect(x: 0, y: 0, width: bounds.width, height: strip)
        scroll.frame = NSRect(x: 0, y: strip, width: bounds.width, height: max(0, bounds.height - strip))
    }
}

/// The colors of the strip (U7, U8): the lane colors of the appearance, the clips in the waveform
/// RMS color in light mode and the peak color in dark mode, and the border of the view frame.
struct OverviewPalette: Equatable {
    var lanes: LanePalette
    var increaseContrast: Bool

    /// Only the dark palette has an accent (`LanePalette.dark`).
    var clip: UInt32 { lanes.accent == nil ? lanes.rms : lanes.peak }
    var borderWidth: Double { increaseContrast ? 2 : 1 }
}

/// The overview strip (decision 0025): the whole session in one image that renders only when the
/// drawn inputs, the palette, or the pixel size change, and never during a live resize (the old
/// image stretches). The view frame, the two dim layers outside it, and the playhead are layers
/// that move at a scroll, a zoom, and a play tick, and render no pixel. No layer animates (U12).
final class OverviewStrip: NSView {
    let image = CALayer()
    let dimLeading = CALayer()
    let dimTrailing = CALayer()
    let viewFrame = CALayer()
    let playhead = CALayer()
    /// A grip at the leading and at the trailing edge of a frame that zooms at its edges (run
    /// 2026-10-11-ui-polish-header C22): the edges show that they can be dragged.
    let grips = [CALayer(), CALayer()]
    /// The image renders, for the count guard (criterion N6).
    private(set) var renders = 0
    /// The value changes that the strip posted, for the accessibility test (criterion N8).
    private(set) var valueChanges = 0
    private var pendingValue: DispatchWorkItem?
    /// The scroll view of the pane: it owns the gesture and the navigation.
    weak var scrollView: TimelineScrollView?

    /// The render key; nil draws no image.
    var inputs: OverviewInputs? {
        didSet { if inputs != oldValue { needsDisplay = true } }
    }
    var palette = OverviewPalette(lanes: .light, increaseContrast: false) {
        didSet { if palette != oldValue { needsDisplay = true } }
    }
    /// The key of the image on screen.
    private var rendered: (inputs: OverviewInputs, palette: OverviewPalette, columns: Int, rows: Int)?
    private var resizing = false
    /// The view of the last move, and the pixel column of the playhead line (the view does not
    /// move it: the strip shows the whole session).
    private var viewport: Viewport?
    private var playheadColumn: Int?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        let still = [
            "position", "bounds", "frame", "contents", "hidden", "backgroundColor", "borderColor", "borderWidth",
        ].reduce(into: [String: any CAAction]()) { $0[$1] = NSNull() }
        let layers: [(CALayer, Double)] =
            [(image, 0), (dimLeading, 1), (dimTrailing, 1), (viewFrame, 2), (playhead, 3)] + grips.map { ($0, 2.5) }
        for (sublayer, z) in layers {
            sublayer.actions = still
            sublayer.zPosition = z
            layer?.addSublayer(sublayer)
        }
        image.contentsGravity = .resize
        image.magnificationFilter = .nearest
        playhead.backgroundColor = NSColor.systemRed.cgColor
        toolTip = L10n.timelineOverviewHelp.text
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(displayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
        place()
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        resizing = true
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        resizing = false
        needsDisplay = true
    }

    // MARK: Palette

    /// The palette of the effective appearance, with the Increase Contrast setting (U8).
    func pickPalette(increaseContrast: Bool = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast) {
        palette = OverviewPalette(lanes: LanePalette.pick(for: effectiveAppearance), increaseContrast: increaseContrast)
    }

    @objc private func displayOptionsChanged() { pickPalette() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        pickPalette()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        pickPalette()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    // MARK: Layers

    /// The view moved or zoomed: the frame, the dim layers, and the playhead take their places.
    func show(_ view: Viewport) {
        viewport = view
        place()
    }

    /// The playhead line at `frame`; it moves only when its pixel column changes.
    func movePlayhead(to frame: Double) {
        guard let viewport else { return }
        let scale = window?.backingScaleFactor ?? 2
        let x = OverviewGeometry(width: bounds.width, end: viewport.end, rate: viewport.rate).x(of: Frames(Int(frame)))
        let column = Int((x * scale).rounded(.down))
        guard column != playheadColumn else { return }
        playheadColumn = column
        playhead.frame = NSRect(x: Double(column) / scale, y: 0, width: 1, height: bounds.height)
    }

    private func place() {
        guard let viewport else { return }
        let strip = OverviewGeometry(width: bounds.width, end: viewport.end, rate: viewport.rate)
        let frame = backingAlignedRect(NSRect(strip.viewFrame(viewport)), options: .alignAllEdgesNearest)
        viewFrame.frame = frame
        dimLeading.frame = NSRect(x: 0, y: 0, width: max(0, frame.minX), height: bounds.height)
        dimTrailing.frame = NSRect(x: frame.maxX, y: 0, width: max(0, bounds.width - frame.maxX), height: bounds.height)
        // In the edge zones: 3 pt inside each edge.
        let edges = strip.viewFrame(viewport).width >= OverviewGeometry.edgeMinimum
        for (grip, x) in zip(grips, [frame.minX, frame.maxX - 3]) {
            grip.isHidden = !edges
            grip.frame = NSRect(x: x, y: frame.midY - 6, width: 3, height: 12)
        }
    }

    // MARK: Mouse and cursor

    private func x(_ event: NSEvent) -> Double { Double(convert(event.locationInWindow, from: nil).x) }

    override func mouseDown(with event: NSEvent) {
        scrollView?.overviewEvent(.down(x: x(event), clicks: event.clickCount))
        showCursor(event)
    }

    override func mouseDragged(with event: NSEvent) {
        scrollView?.overviewEvent(.drag(x: x(event)))
        showCursor(event)
    }

    override func mouseUp(with event: NSEvent) {
        scrollView?.overviewEvent(.up(x: x(event)))
        showCursor(event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard trackingAreas.isEmpty else { return }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { showCursor(event) }
    override func cursorUpdate(with event: NSEvent) { showCursor(event) }

    private func showCursor(_ event: NSEvent) {
        guard let kind = scrollView?.overviewCursor(at: x(event)) else { return }
        NSCursor.timeline(kind).set()
    }

    // MARK: Accessibility (U15)

    /// A discrete input moved the view: a key, a click, or the end of a drag.
    func valueChanged() {
        pendingValue?.cancel()
        pendingValue = nil
        valueChanges += 1
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    /// A mouse wheel event has no end: the value change comes after the gap that ends a burst.
    func valueChangedLater() {
        pendingValue?.cancel()
        let post = DispatchWorkItem { [weak self] in self?.valueChanged() }
        pendingValue = post
        DispatchQueue.main.asyncAfter(deadline: .now() + Navigation.wheelGap, execute: post)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .scrollBar }
    override func accessibilityLabel() -> String? { L10n.timelineOverview.text }
    override func accessibilityValue() -> Any? { viewport?.position ?? 0 }

    /// "<start> to <end> of <length>" in the time format of the ruler.
    override func accessibilityValueDescription() -> String? {
        guard let viewport else { return nil }
        let rate = Double(viewport.rate)
        func time(_ frames: Double) -> String { rulerLabel(frames / rate, tenths: false) }
        return L10n.timelineOverviewValue.format(
            time(viewport.origin), time(viewport.origin + viewport.frames), time(Double(viewport.end.count)))
    }

    override func accessibilityPerformIncrement() -> Bool {
        scrollView?.navigate(.page(.forward))
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        scrollView?.navigate(.page(.backward))
        return true
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        [
            NSAccessibilityCustomAction(name: L10n.timelineOverviewFit.text) { [weak self] in
                self?.scrollView?.navigate(.fitSession)
                return true
            }
        ]
    }

    // MARK: Render

    override func updateLayer() {
        let scale = window?.backingScaleFactor ?? 2
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor(overviewPixel: palette.lanes.lane).cgColor
            viewFrame.borderWidth = palette.borderWidth
            viewFrame.borderColor = (palette.increaseContrast ? NSColor.labelColor : .controlAccentColor).cgColor
            let dim = NSColor.black.withAlphaComponent(palette.lanes.accent == nil ? 0.18 : 0.35).cgColor
            dimLeading.backgroundColor = dim
            dimTrailing.backgroundColor = dim
            for grip in grips { grip.backgroundColor = viewFrame.borderColor }
        }
        image.frame = bounds
        image.contentsScale = scale
        let (columns, rows) = (Int((bounds.width * scale).rounded()), Int((bounds.height * scale).rounded()))
        guard !resizing, let inputs, columns > 0, rows > 0 else { return }
        if let rendered, rendered.inputs == inputs, rendered.palette == palette, rendered.columns == columns,
            rendered.rows == rows
        {
            return
        }
        image.contents = Self.render(OverviewPlan(inputs, columns: columns, height: rows), palette, columns, rows)
        rendered = (inputs, palette, columns, rows)
        renders += 1
    }

    /// The pixels of `plan` in a new buffer that its image owns: nothing writes them again.
    static func render(_ plan: OverviewPlan, _ palette: OverviewPalette, _ columns: Int, _ rows: Int) -> CGImage? {
        let lanes = palette.lanes
        var pixels = [UInt32](repeating: lanes.lane, count: columns * rows)
        for row in plan.tinted {
            for y in plan.rows[row] {
                pixels.replaceSubrange(
                    y * columns..<(y + 1) * columns, with: repeatElement(lanes.selected(lanes.lane), count: columns))
            }
        }
        for (row, spans) in plan.clips.enumerated() {
            for y in plan.rows[row] {
                for span in spans where span.lowerBound < columns {
                    let x = span.clamped(to: 0..<columns)
                    pixels.replaceSubrange(
                        y * columns + x.lowerBound..<y * columns + x.upperBound,
                        with: repeatElement(palette.clip, count: x.count))
                }
            }
        }
        if let band = plan.band?.clamped(to: 0..<columns) {
            for y in 0..<rows {
                for x in band { pixels[y * columns + x] = lanes.selected(pixels[y * columns + x]) }
            }
        }
        for tick in plan.ticks {
            // A chapter tick is longer and 2 px wide: stronger than a marker tick (U7).
            let color = tick.kind == .chapter ? lanes.chapter : lanes.marker
            let width = tick.kind == .chapter ? 2 : 1
            for y in tick.rows.clamped(to: 0..<rows) {
                for x in (tick.column..<tick.column + width).clamped(to: 0..<columns) {
                    pixels[y * columns + x] = color
                }
            }
        }
        guard let provider = CGDataProvider(data: pixels.withUnsafeBytes { Data($0) } as CFData) else { return nil }
        return CGImage(
            width: columns, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: columns * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

extension NSColor {
    /// A BGRA pixel of a palette as an sRGB color.
    convenience init(overviewPixel pixel: UInt32) {
        func channel(_ shift: UInt32) -> Double { Double((pixel >> shift) & 0xFF) / 255 }
        self.init(srgbRed: channel(16), green: channel(8), blue: channel(0), alpha: 1)
    }
}
