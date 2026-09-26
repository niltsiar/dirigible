import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleTimeline
import os

/// The time of each lane draw, at the debug level: `log stream --level debug --predicate
/// 'subsystem == "com.delineas.dirigible"'` shows it (decision 0017, the 8 ms budget of the release
/// build). The system drops debug messages when nothing streams them.
private let drawLog = Logger(subsystem: "com.delineas.dirigible", category: "timeline")

/// The lanes of the timeline (decision 0017, probe D6): as wide as the session at the zoom,
/// flipped, and drawn only in its dirty rect with own pixels. It redraws only when `inputs` or the
/// backing scale changes. The playhead is a layer that moves with no redraw.
final class TimelineDocumentView: NSView {
    let playhead = CALayer()
    /// The calls of `draw(_:)`, for the redraw tests (criteria 10 and 24).
    private(set) var draws = 0
    /// The rect of the last draw, for the dirty-rect test of a drag event.
    private(set) var drawnRect = NSRect.zero
    /// Every drawn input except the backing scale. A new value draws only when it is not equal, and
    /// only the columns of the changed clips, markers, and Marks when nothing else changed (a drag
    /// event): in the rows of the changed lanes, or at full height for a marker or the Marks.
    var inputs: LaneInputs? {
        didSet {
            guard inputs != oldValue else { return }
            if let rect = changedColumns(from: oldValue) { drawPart(rect) } else { drawAll() }
            resize()
        }
    }

    /// The rect of the partial draws since the last full draw. The layer keeps the image of a draw
    /// until one later draw covers its whole rect, so each partial draw also covers the one before
    /// it: a clip drag kept one image per event (code gate 1 item 1).
    private var partial = NSRect.null

    private func drawAll() {
        partial = .null
        needsDisplay = true
    }

    /// Draws `rect` and the partial draws before it. When that union is more than a quarter of the
    /// lanes in view larger than `rect` (an edit far away, or wide new Marks), each next event would
    /// draw it again. Then one full draw frees every image, and the next union starts empty.
    private func drawPart(_ rect: NSRect) {
        // Inputs that draw the same pixels give an empty rect: no draw.
        guard !rect.isEmpty else { return }
        let union = rect.union(partial)
        // The limit counts only the part in view of each rect (code gate 2 item 2).
        let shown = (scrollView?.shown ?? visibleRect).intersection(bounds)
        let area = { (r: NSRect) in r.intersection(shown).width * r.intersection(shown).height }
        // ponytail: a quarter of the lanes in view is a calibration knob; measure again on Apple Silicon (M8).
        if area(union) - area(rect) > area(shown) / 4 { return drawAll() }
        partial = union
        setNeedsDisplay(union)
    }

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
    /// The lane images that Core Animation can still show, with the last one, and their bytes, for
    /// the image-limit tests (timeline-scroll criteria 3 and 4b).
    var liveImages: Int { renderer.liveBuffers().count }
    var liveImageBytes: Int { renderer.liveBuffers().bytes }

    // The layer keeps the image of each region it drew until a later draw covers that region or the
    // region needs display again (timeline-scroll criterion 3). A scroll marks the lanes that it
    // left, so the images of a page turn or a scroll go with no draw. An edit draws in view, and the
    // next draw of the same columns covers it (40 out point changes kept 3 images).

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        guard let superview else { return }
        superview.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: superview)
    }

    /// True from a scroll until its marks run.
    private var marksPending = false

    /// A scroll marks the lanes that it left in a later job of the main queue, after the commit of
    /// its draw: the release of their images does not cost the frame of a page turn. A run-loop
    /// timer did not run in a test process, which runs the main actor on the main queue only.
    @objc private func scrolled() {
        guard !marksPending else { return }
        marksPending = true
        Task { @MainActor [weak self] in
            self?.marksPending = false
            self?.markLeftLanes()
        }
    }

    /// Marks the lanes more than one view away: no draw, and the layer lets the images there go. A
    /// mark next to the view made the layer draw all lanes in view on screen, so the marks keep one
    /// view of distance. Each mark covers all lanes out of that neighborhood: an image whose region
    /// two smaller marks covered in two parts stayed alive.
    private func markLeftLanes() {
        let visible = visibleRect
        let near = visible.insetBy(dx: -visible.width, dy: -visible.height)
        // CGRect.width is never negative, so each size is checked before the rect exists.
        let (left, right) = (near.minX - bounds.minX, bounds.maxX - near.maxX)
        let (top, bottom) = (near.minY - bounds.minY, bounds.maxY - near.maxY)
        if left > 0 { setNeedsDisplay(NSRect(x: bounds.minX, y: bounds.minY, width: left, height: bounds.height)) }
        if right > 0 { setNeedsDisplay(NSRect(x: near.maxX, y: bounds.minY, width: right, height: bounds.height)) }
        if top > 0 { setNeedsDisplay(NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: top)) }
        if bottom > 0 { setNeedsDisplay(NSRect(x: bounds.minX, y: near.maxY, width: bounds.width, height: bottom)) }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
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

    /// As wide as max(end, 10 s) + 2% at the zoom, and at least as wide as the lanes in view.
    func resize() {
        guard let inputs else { return }
        let session = inputs.session
        let end = Double(max(session.end.count, 10 * session.sampleRate)) * 1.02
        let shown = (enclosingScrollView as? TimelineScrollView)?.shown.width ?? 0
        let width = holdsWidth ? frame.width : max(end / inputs.scale.framesPerPoint, Double(shown))
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

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // A snapshot of a layer-backed view (`cacheDisplay`) gives an infinite rect.
        let dirtyRect = dirtyRect.intersection(bounds)
        guard !dirtyRect.isEmpty, let inputs, let context = NSGraphicsContext.current?.cgContext else { return }
        let started = ContinuousClock.now
        draws += 1
        drawnRect = dirtyRect
        let columns = draw(inputs, in: dirtyRect, context)
        let milliseconds = Double((ContinuousClock.now - started) / .microseconds(1)) / 1000
        drawLog.debug("lanes draw \(milliseconds, format: .fixed(precision: 2)) ms, \(columns) columns")
    }

    /// Draws the lanes that `rect` crosses, in its columns, and the labels in it. Gives the pixel
    /// columns.
    private func draw(_ inputs: LaneInputs, in rect: NSRect, _ context: CGContext) -> Int {
        let (x0, x1) = (rect.minX.rounded(.down), rect.maxX.rounded(.up))
        // The lanes that the rect crosses: a drag event on one lane draws only its rows.
        let lanes =
            Int((rect.minY / inputs.laneHeight).rounded(.down))..<Int((rect.maxY / inputs.laneHeight).rounded(.up))
        let (top, height) = (Double(lanes.lowerBound) * inputs.laneHeight, Double(lanes.count) * inputs.laneHeight)
        let scale = window?.backingScaleFactor ?? 2
        guard let image = renderer.draw(inputs, x: x0, width: x1 - x0, scale: scale, lanes: lanes) else { return 0 }
        // The view is flipped: flip the context so row 0 of the image is the top of the first lane.
        context.saveGState()
        context.translateBy(x: x0, y: top + height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: x1 - x0, height: height))
        context.restoreGState()
        drawLabels(inputs, in: rect)
        return Int((x1 - x0) * scale)
    }

    /// The clip label: its file path without `.wav` (Release 1 clips have no name), at the bottom
    /// left of the box, cut at the box end. It reads only the clips in the frames of `rect`, lane by
    /// lane. A box under 60 pt gets no label: 12,000 labels at fit zoom took 330 ms per draw (probe
    /// L1, decision 0020).
    private func drawLabels(_ inputs: LaneInputs, in rect: NSRect) {
        guard inputs.laneHeight > 14, let geometry = inputs.geometry,
            let context = NSGraphicsContext.current?.cgContext
        else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor(white: 0.15, alpha: 1),
        ]
        let frames = geometry.frame(at: rect.minX)..<geometry.frame(at: rect.maxX) + Frames(2)
        for (lane, track) in inputs.session.tracks.enumerated() {
            for clip in track.clips.clips(overlapping: frames) {
                let box = NSRect(geometry.box(of: clip, lane: lane))
                guard box.width >= 60, box.intersects(rect) else { continue }
                let path = inputs.session.files[clip.file]?.path ?? clip.file.rawValue
                let name = path.hasSuffix(".wav") ? String(path.dropLast(4)) : path
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

extension NSCursor {
    /// The cursor of a timeline cursor kind (probe C1: each exists at the macOS 14 target).
    static func timeline(_ kind: TimelineCursor) -> NSCursor {
        switch kind {
        case .arrow: .arrow
        case .iBeam: .iBeam
        case .closedHand: .closedHand
        case .resizeLeftRight: .resizeLeftRight
        }
    }
}

extension NSRect {
    init(_ rect: Rect) { self.init(x: rect.x, y: rect.y, width: rect.width, height: rect.height) }
}
