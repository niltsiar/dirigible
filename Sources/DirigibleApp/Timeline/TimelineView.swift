import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleTimeline
import SwiftUI

/// The lanes, the ruler, and the track headers of a session window (decision 0017). SwiftUI gives
/// only the drawn inputs and the headers; the view draws when the inputs change. The playhead
/// comes from the display link, outside SwiftUI, so a playhead poll updates no SwiftUI view here.
struct TimelineLanes<Headers: View>: NSViewRepresentable {
    let model: SessionWindow
    let studio: Studio
    let inputs: LaneInputs
    /// Row n is the header of lane n, with the lane height.
    let headers: Headers

    /// The header width of the app preferences at open; the handle saves there (decision 0023).
    func makeNSView(context: Context) -> TimelinePaneView {
        let defaults = model.app?.defaults
        let width = HeaderWidth(stored: defaults?.object(forKey: HeaderWidth.defaultsKey))
        let view = TimelineScrollView(model: model, studio: studio, headerWidth: width)
        if let defaults {
            view.headers.save = { defaults.set($0.points, forKey: HeaderWidth.defaultsKey) }
        }
        model.timelineView = view
        return TimelinePaneView(scroll: view)
    }

    func updateNSView(_ pane: TimelinePaneView, context: Context) {
        let view = pane.scroll
        view.updates += 1
        view.headers.host.rootView = AnyView(headers)
        view.update(inputs)
    }
}

/// The scroll view of the lanes: Command-wheel and pinch zoom at the pointer, a user scroll that
/// holds the follow during play, the page turns of Automatic Scroll, the track headers in the
/// vertical ruler, and the visible part that the record-over warning reads.
final class TimelineScrollView: NSScrollView {
    weak var model: SessionWindow?
    /// Weak: a view that outlives its window keeps no studio, and so no package lock.
    weak var studio: Studio?
    let lanes = TimelineDocumentView()
    let ruler: TimelineRuler
    let headers = TrackHeaderRuler()
    /// The overview strip of the pane, if any: tests build the scroll view alone.
    weak var overview: OverviewStrip?
    /// The calls of `updateNSView`, for criterion 24.
    var updates = 0
    /// The target of the display link; the link retains it, and it holds this view weakly.
    private(set) var linkProxy: DisplayLinkProxy?
    private var link: CADisplayLink?
    /// The playhead and the playback of the last tick.
    private var last: (playhead: Double, playback: Playback)?
    /// Zoom to Session at the first layout with a width.
    var fitted = false
    /// The last inputs of SwiftUI, with the Studio session of the last mouse-down or mouse-up. Never
    /// the preview: the lanes draw the gesture over it (decision 0020).
    private(set) var source: LaneInputs?
    /// The one gesture of the lanes.
    private(set) var gesture = TimelineGesture()
    /// The zoom history and the toggles of this window (decision 0025).
    var navigation = Navigation()
    /// The mouse gesture of the overview strip.
    var overviewGesture = OverviewGesture()
    /// The window point of the last lane or ruler drag event, for autoscroll (0025).
    var dragPointer: (window: NSPoint, ruler: Bool)?
    /// The time of the last autoscroll tick, and the time when the pointer entered the zone.
    private var autoscrollTimes: (last: Double, zone: Double?)?

    /// `headerWidth` is the width of the track headers at open.
    init(model: SessionWindow, studio: Studio, headerWidth: HeaderWidth = .standard) {
        self.model = model
        self.studio = studio
        ruler = TimelineRuler(model: model)
        super.init(frame: .zero)
        headers.width = headerWidth
        hasHorizontalScroller = true
        hasVerticalScroller = true
        backgroundColor = .windowBackgroundColor
        documentView = lanes
        ruler.scrollView = self
        ruler.orientation = .horizontalRuler
        horizontalRulerView = ruler
        hasHorizontalRuler = true
        headers.scrollView = self
        headers.orientation = .verticalRuler
        verticalRulerView = headers
        hasVerticalRuler = true
        rulersVisible = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(liveScrollStarted), name: NSScrollView.willStartLiveScrollNotification,
            object: self)
    }

    required init?(coder: NSCoder) { nil }

    var framesPerPoint: Double { lanes.framesPerPoint }
    /// The part of the lanes in view, in document points. The clip view goes under the rulers, and
    /// its content insets are the rulers, so the bounds minus the insets is what the user sees.
    var shown: NSRect {
        let (bounds, insets) = (contentView.bounds, contentView.contentInsets)
        return NSRect(
            x: bounds.minX + insets.left, y: bounds.minY + insets.top,
            width: max(0, bounds.width - insets.left - insets.right),
            height: max(0, bounds.height - insets.top - insets.bottom))
    }
    /// The frame at the left edge of the lanes in view.
    var origin: Double { Double(shown.minX) * framesPerPoint }
    var visibleFrames: Double { Double(shown.width) * framesPerPoint }

    /// A SwiftUI update. Another session during a gesture (an undo, a take) drops the gesture first.
    func update(_ inputs: LaneInputs) {
        if gesture.isActive, let old = source, old.session != inputs.session, let context = context(inputs) {
            model?.apply(gesture.handle(.sessionChanged, context))
        }
        let old = source?.laneHeight
        source = inputs
        redraw()
        if let old, old != inputs.laneHeight { keepTopLane(old: old, new: inputs.laneHeight) }
        fitOnce()
        viewMoved()
    }

    /// A new lane height keeps the lane at the top of the view at the top (0025).
    private func keepTopLane(old: Double, new: Double) {
        let top = Double(shown.minY) * new / old
        contentView.scroll(to: NSPoint(x: contentView.bounds.minX, y: top - contentView.contentInsets.top))
        reflectScrolledClipView(contentView)
    }

    /// A mouse event of the lanes or the ruler. At the mouse-down, the typed track names commit, and the
    /// source takes the Studio session. A drag event does not read the Studio: a change reaches the
    /// gesture through `update`. At the mouse-up: the effects, then the Studio session, then the draw,
    /// so the lanes never draw the session of the mouse-down after a commit.
    func mouse(_ event: GestureEvent) {
        if case .drag = event {} else { dragPointer = nil }
        guard var source, let model, let studio else { return }
        if case .down = event {
            model.commitNames()
            source.session = studio.session
        }
        guard let context = context(source) else { return }
        model.apply(gesture.handle(event, context))
        if case .up = event { source.session = studio.session }
        self.source = source
        redraw()
    }

    /// Esc: true when a gesture ran and Esc ended it.
    func cancelGesture() -> Bool {
        guard gesture.isActive, let source, let context = context(source) else { return false }
        model?.apply(gesture.handle(.escape, context))
        redraw()
        return true
    }

    /// The cursor of the gesture at a lane or ruler point.
    func cursor(at place: Place) -> TimelineCursor {
        guard let source, let context = context(source) else { return .arrow }
        return gesture.cursor(at: place, context)
    }

    /// The frame and the flag of the ruler menu at the document x `x`. Nil during a gesture, so a
    /// right-click does not open a menu over a drag (mouse-edits Q10).
    func menuTarget(at x: Double) -> (frame: Frames, marker: MarkerID?)? {
        guard !gesture.isActive, let source, let context = context(source) else { return nil }
        return TimelineGesture.menuTarget(at: x, context)
    }

    private func context(_ inputs: LaneInputs) -> GestureContext? {
        guard let model, let studio, let geometry = inputs.geometry else { return nil }
        return GestureContext(
            session: inputs.session, marks: model.timeline.marks, playhead: studio.playhead, geometry: geometry,
            canEdit: model.canEdit)
    }

    /// Draws the gesture over the source.
    private func redraw() {
        guard var drawn = source else { return }
        drawn.session = gesture.drawn(drawn.session)
        lanes.holdsWidth = gesture.isActive
        lanes.inputs = drawn
        // The strip shows the committed session, never a preview: it renders at the mouse-up.
        if !gesture.isActive, let source {
            let session = source.session
            overview?.inputs = OverviewInputs(
                session: session, selection: source.marks.selection(in: session)?.range,
                selectedLanes: session.tracks.indices.filter { source.marks.tracks.contains(session.tracks[$0].id) },
                extent: Viewport.extent(end: session.end, rate: session.sampleRate))
        }
        ruler.inputs = drawn.geometry.map {
            RulerInputs(
                markers: drawn.session.markers, marks: drawn.marks, geometry: $0, rate: drawn.session.sampleRate)
        }
    }

    override func tile() {
        // The document point at the top left of the lanes in view, before AppKit moves the bounds.
        let kept = shown.origin
        super.tile()
        keepShownOrigin(kept)
        lanes.resize()
        fitOnce()
        viewMoved()
    }

    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        viewMoved()
    }

    /// The content insets of the clip view at the last tile.
    private var insets = NSEdgeInsetsZero
    /// The left edge of the lanes in view and of the clip view at the last move, in document points.
    private var rulerLeft: (lanes: CGFloat, clip: CGFloat) = (.nan, .nan)

    /// The clip view gets the ruler insets at a tile, after the first fit can scroll. A change of
    /// the insets puts `kept` back at the top left of the lanes in view. A smaller inset makes
    /// AppKit clamp the bounds at the leading edge first, so a shift by the change moved the lanes.
    private func keepShownOrigin(_ kept: NSPoint) {
        let new = contentView.contentInsets
        guard new.left != insets.left || new.top != insets.top else { return }
        contentView.scroll(to: NSPoint(x: kept.x - new.left, y: kept.y - new.top))
        insets = new
    }

    /// The one vertical origin, the top of the clip view, places the headers beside the lanes
    /// and gives the lanes in view. The header ruler and the clip view have the same top.
    private func viewMoved() {
        headers.place(top: contentView.bounds.minY, height: lanes.frame.height)
        // AppKit scrolls the time ruler by a copy of its pixels and draws only the new part, so the
        // times over the lanes moved over the headers. A full draw clips them at the lanes. A header
        // width change at fit zoom keeps the lanes edge and moves the clip edge: the ruler kept 0:00
        // at the old width.
        let left = (lanes: shown.minX, clip: contentView.bounds.minX)
        if left != rulerLeft {
            rulerLeft = left
            ruler.needsDisplay = true
        }
        lanes.shownMoved()
        if let viewport { overview?.show(viewport) }
        publishVisible()
    }

    @objc private func liveScrollStarted() { userScrolled() }

    /// A user scroll during play holds the follow (decision 0017); the play goes on.
    func userScrolled() {
        guard let model, studio?.playback != .stopped, !model.timeline.followHeld else { return }
        model.timeline.followHeld = true
    }

    /// The frames and the whole lanes in view, for the record-over warning. It writes only a
    /// change, so a tick that does not scroll updates no SwiftUI view.
    private func publishVisible() {
        guard let model, let inputs = source, shown.width > 0 else { return }
        // A lane counts when all of it is in view, with half a point of rounding.
        let (top, bottom) = (Double(shown.minY), Double(shown.maxY))
        let first = max(0, Int(((top - 0.5) / inputs.laneHeight).rounded(.up)))
        let end = min(inputs.session.tracks.count, Int((bottom + 0.5) / inputs.laneHeight))
        let visible = TimelineVisible(
            frames: Frames(Int(origin))..<Frames(Int(origin + visibleFrames)), lanes: first..<max(first, end))
        if model.timeline.visible != visible { model.timeline.visible = visible }
    }

    // MARK: Display link

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, link == nil else { return }
        let proxy = DisplayLinkProxy()
        proxy.view = self
        link = displayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick(_:)))
        link?.add(to: .main, forMode: .common)
        linkProxy = proxy
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        guard newWindow == nil else { return }
        link?.invalidate()
        link = nil
        linkProxy = nil
    }

    /// One display tick: the playhead line between two polls, and the follow.
    func displayTick() {
        guard let studio else { return }
        let playback = studio.playback
        let frame = playheadFrame(
            polled: studio.playhead, at: studio.playheadTime, now: .now, playback: playback,
            rate: studio.session.sampleRate)
        tick(playhead: frame, playback: playback)
        autoscrollTick(at: CACurrentMediaTime())
    }

    /// Autoscroll (0025, U16): during a drag with the pointer past the lanes edge, the lanes scroll
    /// and the drag goes again at the same window point, so a still pointer also moves the clip.
    /// The lanes keep their width during the gesture (0020), so the scroll stops at the held width.
    func autoscrollTick(at now: Double) {
        guard gesture.autoscrolls, let pointer = dragPointer, shown.width > 0 else {
            autoscrollTimes = nil
            return
        }
        let x = Double(lanes.convert(pointer.window, from: nil).x - shown.minX)
        // A lanes edge on the screen edge: the pointer cannot go past it (a maximized window).
        let edges = window?.convertToScreen(lanes.convert(shown, to: nil)) ?? .zero
        let screen = window?.screen?.frame
        let atScreen = (
            screen.map { edges.minX <= $0.minX + 1 } ?? false, screen.map { edges.maxX >= $0.maxX - 1 } ?? false
        )
        let times = autoscrollTimes ?? (last: now - 1.0 / 60, zone: nil)
        let zone = times.zone ?? now
        let step = autoscrollStep(
            x: x, width: Double(shown.width), edgesAtScreen: atScreen, secondsInZone: now - zone,
            tick: min(now - times.last, 0.1))
        autoscrollTimes = (now, step == 0 ? nil : zone)
        // The clip view does not clamp a scroll: stop at 0 and at the held width of the lanes.
        let last = Double(lanes.frame.width - shown.width) * framesPerPoint
        let target = min(max(origin + step * framesPerPoint, 0), max(0, last))
        guard target != origin else { return }
        userScrolled()
        scroll(toFrame: target)
        let point = lanes.convert(pointer.window, from: nil)
        let y = pointer.ruler ? Double(ruler.convert(pointer.window, from: nil).y) : Double(point.y)
        mouse(.drag(pointer.ruler ? .ruler(x: Double(point.x), y: y) : .lanes(x: Double(point.x), y: y)))
    }

    /// Moves the playhead line. During play, the follow can turn the page. A play start, a
    /// shuttle change, or a move of the playhead while stopped (a seek) ends a hold and shows
    /// the playhead when it is off the page. The first tick only takes the state.
    func tick(playhead: Double, playback: Playback) {
        lanes.movePlayhead(to: playhead)
        overview?.movePlayhead(to: playhead)
        defer { last = (playhead, playback) }
        guard let model, let last else { return }
        let started = playback != .stopped && playback != last.playback
        let seeked = playback == .stopped && playhead != last.playhead
        guard playback != .stopped || seeked else { return }
        var state = model.timeline
        if started || seeked { state.followHeld = false }
        let direction: Shuttle.Direction
        if case .playing(let shuttle) = playback { direction = shuttle.direction } else { direction = .forward }
        let turn = state.follow(
            playhead: Frames(Int(playhead)), origin: origin, frames: visibleFrames, direction: direction)
        if state.followHeld != model.timeline.followHeld { model.timeline.followHeld = state.followHeld }
        if let turn { scroll(toFrame: turn) }
    }
}

/// The target of the display link. `CADisplayLink` retains it, and it holds the view weakly,
/// so a link that outlives the view keeps only this small object.
@MainActor final class DisplayLinkProxy: NSObject {
    weak var view: TimelineScrollView?
    /// The ticks, for the test of the link end.
    private(set) var ticks = 0

    @objc func tick(_ link: CADisplayLink) {
        ticks += 1
        view?.displayTick()
    }
}
