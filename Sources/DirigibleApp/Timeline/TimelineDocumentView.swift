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
/// renders only its dirty rect and the columns that a scroll shows. It redraws when `inputs` or
/// the backing scale changes, and at the live ticks of a take (`liveMoved`, `liveChanged`). The
/// playhead is a layer that moves with no redraw.
final class TimelineDocumentView: NSView {
    let playhead = PlayheadLine()
    /// The snap guide (snap run).
    let guide = GuideLayer()
    /// The red line at T during the pre-roll of a take (decision 0070).
    let preRollLine = PreRollLine()
    /// The marquee of a Shift-drag (decision 0038).
    let marquee = MarqueeLayer()
    /// The value of a gain or fade-handle drag at the pointer (run 11b-1).
    let readout = ReadoutLayer()
    /// The live take comes from here at each draw (`LiveLanes`). Weak, as in the scroll view.
    weak var studio: Studio?
    /// The record head of the last live tick. Nil when no take records or finalizes.
    private(set) var liveHead: Frames?
    /// Increase Contrast: the playhead is 2 pt wide, else 1 pt. The display options set it.
    var increasesContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
        didSet {
            resize()
            showPlayheadColors()
        }
    }
    /// True while the line is the record head of a take.
    private var taking = false
    /// The pixels of the lanes in view.
    let surfaces = LaneSurfaces()
    /// The dim of the lanes that are not heard (decision 0039).
    let dim = LaneShade()
    /// The tint of the lanes of the selected tracks, above the dim (run 2026-10-11-ui-polish-header
    /// C11).
    let tint = LaneShade()
    /// The silences of the Silences tab and their planned cuts, above the tint (decision 0066).
    let silenceShade = SilenceShade()
    var silenceBands: [SilenceBand] = [] {
        didSet { if silenceBands != oldValue { updateShades() } }
    }
    /// A drag of audio files from the Finder (run 13c).
    let drop = LaneDrop()
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
            let first = pending.isNull
            if let rect = changedColumns(from: oldValue) {
                // Inputs that draw the same pixels give an empty rect: no draw.
                if !rect.isEmpty { setNeedsDisplay(rect) }
                pendingShift = first ? shift(from: oldValue) : nil
            } else {
                needsDisplay = true
            }
            resize()
        }
    }

    /// The document rect to render at the next `updateLayer()`.
    private var pending = NSRect.null
    /// The shift of a ripple drag for the next `updateLayer()` (decision 0037). Each other display
    /// request clears it, so it applies only when it is the one change since the last draw.
    var pendingShift: ShiftedFrames?

    override func setNeedsDisplay(_ rect: NSRect) {
        pending = pending.union(rect)
        pendingShift = nil
        super.setNeedsDisplay(rect)
    }

    override var needsDisplay: Bool {
        get { super.needsDisplay }
        set {
            if newValue { (pending, pendingShift) = (bounds, nil) }
            super.needsDisplay = newValue
        }
    }

    override var wantsUpdateLayer: Bool { true }
    /// The lanes render only the lanes in view, so AppKit asks for no rect outside them.
    override class var isCompatibleWithResponsiveScrolling: Bool { false }

    /// The lanes in view moved (a scroll or a new size): `updateLayer()` shows the new window with
    /// no dirty rect, so it renders only the pixels that the last window did not hold.
    func shownMoved() { layer?.setNeedsDisplay() }

    /// An append to the live store at a tick: marks the columns from the lowest added frame or
    /// the head of the last live tick, the lower, to `head`, with 1 pt on each side for the
    /// rounding. The rect has the full height (the 360 pt rule of `changedColumns`).
    func liveMoved(head: Frames, from: Frames?) {
        defer { liveHead = head }
        guard let geometry = inputs?.geometry else { return }
        let low = min(from ?? head, liveHead ?? head, head)
        let (x0, x1) = (geometry.x(of: low).rounded(.down), geometry.x(of: head).rounded(.up))
        setNeedsDisplay(NSRect(x: x0 - 1, y: 0, width: x1 - x0 + 2, height: bounds.height))
    }

    /// Another change of the live take (a take start, a stop, a track state, the hand-off, a
    /// finalize error): the lanes in view draw again.
    func liveChanged(head: Frames?) {
        liveHead = head
        needsDisplay = true
    }

    /// The columns of the clips, markers, and Marks that changed from `old`, with 1 pt on each side
    /// for the rounding of the renderer, in the rows of the changed lanes (all rows for new Marks).
    /// Nil when another input changed.
    private func changedColumns(from old: LaneInputs?) -> NSRect? {
        guard var old, let inputs, let geometry = inputs.geometry,
            let clips = changedFrames(from: old.session, to: inputs.session)
        else { return nil }
        let marks = changedFrames(from: old.selection, to: inputs.selection, in: inputs.session)
        (old.session, old.selection) = (inputs.session, inputs.selection)
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
        didSet {
            needsDisplay = true
            updateShades()
            drop.palette = palette
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(surfaces.layer)
        layer?.addSublayer(dim.layer)
        layer?.addSublayer(tint.layer)
        layer?.addSublayer(silenceShade.layer)
        layer?.addSublayer(drop.layer)
        playhead.zPosition = 10
        showPlayheadColors()
        layer?.addSublayer(playhead)
        layer?.addSublayer(preRollLine)
        layer?.addSublayer(guide)
        layer?.addSublayer(marquee)
        readout.zPosition = 20
        layer?.addSublayer(readout)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(L10n.timelineAccessibility.text)
        toolTip = L10n.timelineHelpRollSlip.text
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(displayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    @objc private func displayOptionsChanged() {
        increasesContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
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
        didSet {
            guard oldValue, !holdsWidth else { return }
            resize()
            // A shift of a gesture at a zoom that is not whole rounded its frames: one full draw.
            if roundedShift { (needsDisplay, roundedShift) = (true, false) }
        }
    }

    /// True after a shift whose move in frames is not exactly its move in columns (a zoom that is
    /// not a whole number of frames per point). The end of the gesture draws the lanes in full.
    var roundedShift = false

    /// The width of `Viewport.documentWidth` at the one end of the scroll view (the held end of a
    /// take), or the width of the mouse-down during a gesture.
    func resize() {
        guard let inputs else { return }
        let session = inputs.session
        let width =
            holdsWidth
            ? frame.width
            : Viewport.documentWidth(
                end: scrollView?.end(of: session) ?? session.end, rate: session.sampleRate, scale: inputs.scale,
                shown: Double(scrollView?.shown.width ?? 0))
        let height = Double(session.tracks.count) * inputs.laneHeight
        if frame.size != NSSize(width: width, height: height) { setFrameSize(NSSize(width: width, height: height)) }
        playhead.resize(width: increasesContrast ? 2 : 1, height: height)
        updateShades()
    }

    private func updateShades() {
        guard let inputs else { return }
        let (height, width) = (inputs.laneHeight, frame.width)
        dim.update(
            lanes: LaneShade.unheard(inputs.session), laneHeight: height, width: width, color: palette.lane, alpha: 0.5)
        // The accent at 8 % in light mode and 10 % in Dark Mode: only the dark palette has an accent.
        let alpha = palette.accent == nil ? 0.08 : 0.10
        tint.update(
            lanes: LaneShade.selected(inputs), laneHeight: height, width: width, color: palette.outline, alpha: alpha)
        silenceShade.update(
            bands: silenceBands, geometry: inputs.geometry, height: Double(inputs.session.tracks.count) * height,
            width: width, contrast: increasesContrast, color: palette.outline)
    }

    private func showPlayheadColors() {
        playhead.apply(PlayheadColors(appearance: effectiveAppearance, taking: taking))
        scrollView?.ruler.head.show(appearance: effectiveAppearance, wide: increasesContrast)
    }

    /// Moves the playhead line to `frame`, with no redraw of the lanes. During a take (`taking`) the
    /// line is the record head and red.
    func movePlayhead(to frame: Double, taking: Bool) {
        if taking != self.taking {
            self.taking = taking
            showPlayheadColors()
        }
        playhead.position = CGPoint(x: frame / framesPerPoint, y: bounds.height / 2)
        showPreRollLine(studio?.preRollFrame)
    }

    /// The line at T on the lanes and the mark on the ruler while a pre-roll take plays before T; nil
    /// hides both.
    private func showPreRollLine(_ frame: Frames?) {
        let x = frame.map { Double($0.count) / framesPerPoint }
        preRollLine.show(
            at: x, width: increasesContrast ? 2 : 1, height: bounds.height, appearance: effectiveAppearance)
        scrollView?.ruler.showPreRoll(atDocumentX: x)
    }

    /// The snap guide at `frame` with the width rule of the playhead; nil hides it (snap run).
    func showGuide(_ frame: Frames?) {
        guide.show(
            at: frame.map { Double($0.count) / framesPerPoint }, width: increasesContrast ? 2 : 1,
            height: bounds.height)
    }

    /// The marquee at `rect` in document points with the width rule of the playhead; nil hides it.
    func showMarquee(_ rect: Rect?) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            marquee.show(rect.map(NSRect.init), width: increasesContrast ? 2 : 1)
        }
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
        // The line is dark or light by the appearance, also when the lane palette stays.
        showPlayheadColors()
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
        // `pending` stays for the draw after the session of SwiftUI.
        if scrollView?.handOffWaits == true { return }
        let started = ContinuousClock.now
        let dirty = pending
        let shift = pendingShift.flatMap { laneShift($0, dirty, lanes) }
        (pending, pendingShift) = (.null, nil)
        let live = studio.map { LiveLanes($0, head: liveHead) } ?? LiveLanes()
        let drawn: PixelRect
        switch surfaces.show(
            lanes, changed: lanes.pixels(of: dirty), shift: shift,
            draw: { region in
                Self.drawLanes(renderer, inputs, palette, live: live, into: region)
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

    /// Shows `value` at the document point `point`, or hides the readout when it is nil.
    func showReadout(_ value: GestureReadout?, at point: NSPoint) {
        // The lanes that the user sees: the clip view goes under the rulers.
        let shown = (scrollView?.shown ?? visibleRect).intersection(bounds)
        readout.show(value, at: point, in: shown, rate: inputs?.session.sampleRate ?? 48_000, view: self)
    }

    /// The events go to the gesture of the scroll view (decision 0020).
    var scrollView: TimelineScrollView? { enclosingScrollView as? TimelineScrollView }

    /// The modifier keys that the hover path reads. `flagsChanged` reaches only the first
    /// responder, so a hover with the focus in a name field reads the keys here (decision 0037).
    /// A test sets it: it cannot set `NSEvent.modifierFlags`.
    var modifierFlags: () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }
    /// The last cursor kind that the lanes set, and the lane point of the last hover or mouse
    /// event.
    var shownCursor: TimelineCursor?
    var hoverPlace: Place?

    /// Command at the last mouse or modifier event: a drag with Command does not snap (snap run).
    var commandHeld = false
}
