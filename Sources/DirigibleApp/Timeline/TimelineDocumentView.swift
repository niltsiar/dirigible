import AppKit
import DirigibleAudio
import DirigibleCore
import os

/// The time of each lane draw, at the debug level: `log stream --level debug --predicate
/// 'subsystem == "com.delineas.dirigible"'` shows it (decision 0017, the 8 ms budget of the release
/// build). The system drops debug messages when nothing streams them.
private let drawLog = Logger(subsystem: "com.delineas.dirigible", category: "timeline")

/// The lanes of the timeline (decision 0017, probe D6): as wide as the session at the zoom,
/// flipped, and drawn only in its dirty rect with own pixels. It redraws only when `inputs` or the
/// backing scale changes. The playhead is a layer that moves with no redraw.
final class TimelineDocumentView: NSView {
    weak var model: SessionWindow?
    let playhead = CALayer()
    /// The calls of `draw(_:)`, for the redraw tests (criteria 10 and 24).
    private(set) var draws = 0
    /// Every drawn input except the backing scale. A new value draws only when it is not equal.
    var inputs: LaneInputs? {
        didSet {
            guard inputs != oldValue else { return }
            needsDisplay = true
            resize()
        }
    }
    private let renderer = LaneRenderer()
    /// The mouse-down point, and true once the pointer moved 3 pt or more (a drag).
    private var down: (point: NSPoint, dragging: Bool)?

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

    /// The box of a clip in the document view.
    func clipFrame(_ id: ClipID) -> NSRect? {
        guard let inputs, let (clip, track) = inputs.session.clip(id),
            let lane = inputs.session.tracks.firstIndex(where: { $0.id == track })
        else { return nil }
        let points = inputs.scale.framesPerPoint
        return NSRect(
            x: Double(clip.start.count) / points, y: Double(lane) * inputs.laneHeight,
            width: Double(clip.length.count) / points, height: inputs.laneHeight)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let inputs, let context = NSGraphicsContext.current?.cgContext else { return }
        let started = ContinuousClock.now
        draws += 1
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
    /// left of the box.
    private func drawLabels(_ inputs: LaneInputs, in rect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor(white: 0.15, alpha: 1),
        ]
        for track in inputs.session.tracks {
            for clip in track.clips {
                guard let box = clipFrame(clip.id), box.intersects(rect), box.height > 14 else { continue }
                let path = inputs.session.files[clip.file]?.path ?? clip.file.rawValue
                let name = path.hasSuffix(".wav") ? String(path.dropLast(4)) : path
                name.draw(at: NSPoint(x: box.minX + 4, y: box.maxY - 14), withAttributes: attributes)
            }
        }
    }

    // MARK: Mouse

    private func frame(at x: Double) -> Frames { Frames(Int(max(0, x) * framesPerPoint)) }
    private func lane(at y: Double) -> Int { Int(max(0, y) / (inputs?.laneHeight ?? 1)) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        down = (convert(event.locationInWindow, from: nil), false)
    }

    override func mouseDragged(with event: NSEvent) {
        guard var down else { return }
        let point = convert(event.locationInWindow, from: nil)
        if !down.dragging {
            guard hypot(point.x - down.point.x, point.y - down.point.y) >= 3 else { return }
            down.dragging = true
            self.down = down
        }
        model?.timelineDrag(
            from: frame(at: down.point.x), to: frame(at: point.x), lanes: (lane(at: down.point.y), lane(at: point.y)))
    }

    /// Under 3 pt of movement: a click.
    override func mouseUp(with event: NSEvent) {
        guard let down else { return }
        if down.dragging {
            mouseDragged(with: event)
        } else {
            model?.timelineClick(
                at: frame(at: down.point.x), lane: lane(at: down.point.y),
                shift: event.modifierFlags.contains(.shift), command: event.modifierFlags.contains(.command))
        }
        self.down = nil
    }
}
