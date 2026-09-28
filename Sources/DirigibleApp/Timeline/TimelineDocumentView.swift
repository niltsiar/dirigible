import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleTimeline
import os

/// The time of each lane draw, at the debug level: `log stream --level debug --predicate
/// 'subsystem == "com.delineas.dirigible"'` shows it (decision 0017, the 8 ms budget of the release
/// build). The system drops debug messages when nothing streams them.
private let drawLog = Logger(subsystem: "com.delineas.dirigible", category: "timeline")

/// The lanes of the timeline (decisions 0017 and 0022, probe D6): as wide as the session at the
/// zoom, flipped, with one layer of the lanes in view that `updateLayer()` writes in place. It
/// renders only its dirty rect and the columns that a scroll shows. It redraws only when `inputs`
/// or the backing scale changes. The playhead is a layer that moves with no redraw.
final class TimelineDocumentView: NSView {
    let playhead = CALayer()
    /// The pixels of the lanes in view.
    let surfaces = LaneSurfaces()
    /// The renders, for the redraw tests (criteria 10 and 24).
    private(set) var draws = 0
    /// The rect of the last render, for the dirty-rect test of a drag event.
    private(set) var drawnRect = NSRect.zero
    /// Every drawn input except the backing scale. A new value draws only when it is not equal, and
    /// only the columns of the changed clips, markers, and Marks when nothing else changed (a drag
    /// event): in the rows of the changed lanes, or at full height for a marker or the Marks.
    var inputs: LaneInputs? {
        didSet {
            guard inputs != oldValue else { return }
            if let rect = changedColumns(from: oldValue) {
                // Inputs that draw the same pixels give an empty rect: no draw.
                if !rect.isEmpty { setNeedsDisplay(rect) }
            } else {
                needsDisplay = true
            }
            resize()
        }
    }

    /// The document rect to render at the next `updateLayer()`.
    private var pending = NSRect.null

    override func setNeedsDisplay(_ rect: NSRect) {
        pending = pending.union(rect)
        super.setNeedsDisplay(rect)
    }

    override var needsDisplay: Bool {
        get { super.needsDisplay }
        set {
            if newValue { pending = bounds }
            super.needsDisplay = newValue
        }
    }

    override var wantsUpdateLayer: Bool { true }
    /// The lanes render only the lanes in view, so AppKit asks for no rect outside them.
    override class var isCompatibleWithResponsiveScrolling: Bool { false }

    /// The lanes in view moved (a scroll or a new size): `updateLayer()` shows the new window with
    /// no dirty rect, so it renders only the pixels that the last window did not hold.
    func shownMoved() { layer?.setNeedsDisplay() }

    /// The columns of the clips, markers, and Marks that changed from `old`, with 1 pt on each side
    /// for the rounding of the renderer, in the rows of the changed lanes (all rows for new Marks).
    /// Nil when another input changed.
    private func changedColumns(from old: LaneInputs?) -> NSRect? {
        guard var old, let inputs, let geometry = inputs.geometry,
            let clips = changedFrames(from: old.session, to: inputs.session)
        else { return nil }
        let marks = changedFrames(from: old.marks, to: inputs.marks, in: inputs.session)
        (old.session, old.marks) = (inputs.session, inputs.marks)
        guard old == inputs else { return nil }
        let changed = [clips.frames, marks].filter { !$0.isEmpty }
        guard let low = changed.map(\.lowerBound).min(), let high = changed.map(\.upperBound).max() else {
            return .zero
        }
        let (x0, x1) = (geometry.x(of: low).rounded(.down), geometry.x(of: high).rounded(.up))
        // Only a wide rect takes the rows of its lanes. A narrow rect of part of the height made
        // the flush wait for the window server (11 ms p95 against 3 ms at full height, the Intel
        // Mac of the mouse-edits run), and its full height costs under 1 ms.
        // ponytail: a fixed 360 pt; measure again on Apple Silicon (manual check M8).
        let wide = x1 - x0 >= 360 && marks.isEmpty
        let lanes = wide ? clips.lanes : 0..<inputs.session.tracks.count
        let (y0, y1) = (Double(lanes.lowerBound) * inputs.laneHeight, Double(lanes.upperBound) * inputs.laneHeight)
        return NSRect(x: x0 - 1, y: y0, width: x1 - x0 + 2, height: y1 - y0)
    }

    private let renderer = LaneRenderer()

    /// The lane colors: a drawn input, so a change renders the lanes in view in full.
    var palette = LanePalette.light {
        didSet { needsDisplay = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(surfaces.layer)
        playhead.backgroundColor = NSColor.systemRed.cgColor
        playhead.zPosition = 10
        playhead.actions = ["position": NSNull(), "bounds": NSNull()]
        layer?.addSublayer(playhead)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(L10n.timelineAccessibility.text)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    var framesPerPoint: Double { inputs?.scale.framesPerPoint ?? 512 }

    /// True during a mouse gesture: the lanes keep their width. AppKit draws the new columns of a
    /// wider view at full height, and the draw joins them to the rows of a drag event, so a move
    /// past the session end drew all lanes. The lanes are at least as wide as the view, so the part
    /// past them is not in view; the mouse-up gives the new width.
    var holdsWidth = false {
        didSet { if oldValue, !holdsWidth { resize() } }
    }

    /// The width of `Viewport.documentWidth`, or the width of the mouse-down during a gesture.
    func resize() {
        guard let inputs else { return }
        let session = inputs.session
        let shown = (enclosingScrollView as? TimelineScrollView)?.shown.width ?? 0
        let width =
            holdsWidth
            ? frame.width
            : Viewport.documentWidth(
                end: session.end, rate: session.sampleRate, scale: inputs.scale, shown: Double(shown))
        let height = Double(session.tracks.count) * inputs.laneHeight
        if frame.size != NSSize(width: width, height: height) { setFrameSize(NSSize(width: width, height: height)) }
        playhead.bounds = CGRect(x: 0, y: 0, width: 1, height: height)
    }

    /// Moves the playhead line to `frame`, with no redraw of the lanes.
    func movePlayhead(to frame: Double) {
        playhead.position = CGPoint(x: frame / framesPerPoint, y: bounds.height / 2)
    }

    /// The box of a clip in the document view: the box of `LaneGeometry` (decision 0020).
    func clipFrame(_ id: ClipID) -> NSRect? {
        guard let inputs, let geometry = inputs.geometry, let (clip, track) = inputs.session.clip(id),
            let lane = inputs.session.tracks.firstIndex(where: { $0.id == track })
        else { return nil }
        return NSRect(geometry.box(of: clip, lane: lane))
    }

    /// The one pick of the palette. A change only sets a new palette.
    func pickPalette() {
        let picked = LanePalette.pick(for: effectiveAppearance)
        if picked != palette { palette = picked }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        pickPalette()
    }

    /// A view of an app in Dark Mode is dark before it enters its window, so the move gives no
    /// appearance change (probe Q6). AppKit gave one more call at open in the app, but no
    /// documentation says so (code gate 2 item 1).
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        pickPalette()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    /// The display pass, before the commit: shows the lanes in view with the dirty rect rendered,
    /// so a scroll, the frame of the layer, and its contents commit in one transaction.
    override func updateLayer() {
        guard let inputs,
            let lanes = LaneWindow(
                view: scrollView?.shown ?? visibleRect, bounds: bounds, laneHeight: inputs.laneHeight,
                lanes: inputs.session.tracks.count, scale: Double(window?.backingScaleFactor ?? 2),
                room: Double(scrollView?.contentView.bounds.width ?? 0))
        else { return }
        let started = ContinuousClock.now
        let dirty = pending
        pending = .null
        let drawn: PixelRect
        switch surfaces.show(
            lanes, changed: lanes.pixels(of: dirty),
            draw: { region in
                renderer.draw(inputs, palette, into: region)
                Self.drawLabels(inputs, palette, into: region)
            })
        {
        case .drawn(let rect): drawn = rect
        case .unchanged: return
        case .refused:
            // The layer shows the old pixels. Keep the change and try again one frame later: a
            // display request in `updateLayer()` displays again in the same commit, with no end.
            drawLog.error("lanes draw refused: no surface for \(lanes.capacity.columns) x \(lanes.capacity.rows) px")
            pending = pending.union(dirty)
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16)) { [weak self] in
                self?.layer?.setNeedsDisplay()
            }
            return
        }
        draws += 1
        drawnRect = lanes.points(of: drawn)
        let milliseconds = Double((ContinuousClock.now - started) / .microseconds(1)) / 1000
        drawLog.debug("lanes draw \(milliseconds, format: .fixed(precision: 2)) ms, \(drawn.columns.count) columns")
    }

    /// The clip label: its file path without `.wav` (Release 1 clips have no name), at the bottom
    /// left of the box, cut at the box end. It reads only the clips in the frames of the rect of
    /// `region`, lane by lane, and draws only in that rect. A box under 60 pt gets no label: 12,000
    /// labels at fit zoom took 330 ms per draw (probe L1, decision 0020).
    static func drawLabels(_ inputs: LaneInputs, _ palette: LanePalette, into region: borrowing PixelRegion) {
        guard inputs.laneHeight > 14, let geometry = inputs.geometry, !region.rect.isEmpty else { return }
        let rect = region.window.points(of: region.rect)
        let frames = geometry.frame(at: rect.minX)..<geometry.frame(at: rect.maxX) + Frames(2)
        var labels: [(box: NSRect, name: String)] = []
        for (lane, track) in inputs.session.tracks.enumerated() {
            for clip in track.clips.clips(overlapping: frames) {
                let box = NSRect(geometry.box(of: clip, lane: lane))
                guard box.width >= 60, box.intersects(rect) else { continue }
                let path = inputs.session.files[clip.file]?.path ?? clip.file.rawValue
                labels.append((box, path.hasSuffix(".wav") ? String(path.dropLast(4)) : path))
            }
        }
        guard !labels.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10), .foregroundColor: palette.labelColor,
        ]
        region.withContext { context in
            let previous = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            defer { NSGraphicsContext.current = previous }
            for (box, name) in labels {
                // Only in its box: the dirty rect of a drag event holds the boxes it changes.
                context.saveGState()
                context.clip(to: box)
                name.draw(at: NSPoint(x: box.minX + 4, y: box.maxY - 14), withAttributes: attributes)
                context.restoreGState()
            }
        }
    }

    // MARK: Mouse

    /// The events go to the gesture of the scroll view (decision 0020).
    private var scrollView: TimelineScrollView? { enclosingScrollView as? TimelineScrollView }

    private func place(_ event: NSEvent) -> Place {
        let point = convert(event.locationInWindow, from: nil)
        return .lanes(x: Double(point.x), y: Double(point.y))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let flags = event.modifierFlags
        scrollView?.mouse(.down(place(event), shift: flags.contains(.shift), command: flags.contains(.command)))
        showCursor(event)
    }

    override func mouseDragged(with event: NSEvent) {
        scrollView?.mouse(.drag(place(event)))
        scrollView?.dragPointer = (event.locationInWindow, ruler: false)
        showCursor(event)
    }

    override func mouseUp(with event: NSEvent) {
        scrollView?.mouse(.up(place(event)))
        showCursor(event)
    }

    // MARK: Cursor

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
        guard let kind = scrollView?.cursor(at: place(event)) else { return }
        NSCursor.timeline(kind).set()
    }
}

extension LanePalette {
    /// The palette of `appearance`: the appearance and the accent resolve together.
    static func pick(for appearance: NSAppearance) -> LanePalette {
        var picked = LanePalette.light
        appearance.performAsCurrentDrawingAppearance {
            guard appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua,
                let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB)
            else { return }
            func channel(_ value: CGFloat) -> UInt32 { UInt32((value * 255).rounded()) }
            picked = .dark(
                accent: 0xFF00_0000 | channel(accent.redComponent) << 16 | channel(accent.greenComponent) << 8
                    | channel(accent.blueComponent))
        }
        return picked
    }
}

extension NSCursor {
    /// The cursor of a timeline cursor kind (probe C1: each exists at the macOS 14 target).
    static func timeline(_ kind: TimelineCursor) -> NSCursor {
        switch kind {
        case .arrow: .arrow
        case .iBeam: .iBeam
        case .openHand: .openHand
        case .closedHand: .closedHand
        case .resizeLeftRight: .resizeLeftRight
        }
    }
}

extension NSRect {
    init(_ rect: Rect) { self.init(x: rect.x, y: rect.y, width: rect.width, height: rect.height) }
}
