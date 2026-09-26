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
    /// only the columns of the changed clips and markers when nothing else changed (a drag event).
    var inputs: LaneInputs? {
        didSet {
            guard inputs != oldValue else { return }
            if let rect = changedColumns(from: oldValue) { setNeedsDisplay(rect) } else { needsDisplay = true }
            resize()
        }
    }

    /// The columns of the clips and markers that changed from `old`, at full height, with 1 pt on each side for
    /// the rounding of the renderer. Nil when another input changed.
    private func changedColumns(from old: LaneInputs?) -> NSRect? {
        guard var old, let inputs, let geometry = inputs.geometry,
            let frames = changedFrames(from: old.session, to: inputs.session)
        else { return nil }
        old.session = inputs.session
        guard old == inputs else { return nil }
        let (x0, x1) = (
            geometry.x(of: frames.lowerBound).rounded(.down), geometry.x(of: frames.upperBound).rounded(.up)
        )
        return NSRect(x: x0 - 1, y: 0, width: x1 - x0 + 2, height: bounds.height)
    }

    private let renderer = LaneRenderer()

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

    /// As wide as max(end, 10 s) + 2% at the zoom, and at least as wide as the lanes in view.
    func resize() {
        guard let inputs else { return }
        let session = inputs.session
        let end = Double(max(session.end.count, 10 * session.sampleRate)) * 1.02
        let shown = (enclosingScrollView as? TimelineScrollView)?.shown.width ?? 0
        let width = max(end / inputs.scale.framesPerPoint, Double(shown))
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
        let (x0, x1) = (dirtyRect.minX.rounded(.down), dirtyRect.maxX.rounded(.up))
        let height = Double(inputs.session.tracks.count) * inputs.laneHeight
        let scale = window?.backingScaleFactor ?? 2
        guard let image = renderer.draw(inputs, x: x0, width: x1 - x0, scale: scale) else { return }
        // The view is flipped: flip the context so row 0 of the image is the top of lane 1.
        context.saveGState()
        context.translateBy(x: x0, y: height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: x1 - x0, height: height))
        context.restoreGState()
        drawLabels(inputs, in: dirtyRect)
        let milliseconds = Double((ContinuousClock.now - started) / .microseconds(1)) / 1000
        let columns = Int((x1 - x0) * scale)
        drawLog.debug("lanes draw \(milliseconds, format: .fixed(precision: 2)) ms, \(columns) columns")
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
