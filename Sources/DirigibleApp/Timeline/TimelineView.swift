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
/// holds the follow during play or a take, the page turns of Automatic Scroll, the track headers
/// in the vertical ruler, and the visible part that the record-over warning reads.
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
    /// The playhead, the playback, and the take state of the last tick.
    private var last: (playhead: Double, playback: Playback, taking: Bool)?
    /// The end that a take holds (live take view): during a take, the next minute strictly above
    /// the head + the frames in view; after it, the frame at the right edge of the view at the
    /// hand-off. A navigation input after the take drops it.
    private(set) var heldEnd: Frames?
    /// The live store and the live key of the last live draw (`liveTick`).
    var liveSeen = (version: 0, epoch: 0, key: LiveKey())
    /// The first view is shown: the last view of the window, else the fit at open.
    var fitted = false
    /// The last inputs of SwiftUI, with the Studio session of the last mouse-down or mouse-up. Never
    /// the preview: the lanes draw the gesture over it (decision 0020).
    private(set) var source: LaneInputs?
    /// The one gesture of the lanes.
    private(set) var gesture = TimelineGesture()
    /// The document point of the last lane event, also of an autoscroll drag: the readout is there.
    private var lanePoint = NSPoint.zero
    /// The mouse gesture of the overview strip.
    var overviewGesture = OverviewGesture()
    /// The window point of the last lane or ruler drag event, for autoscroll (0025).
    var dragPointer: (window: NSPoint, ruler: Bool)?
    /// The time of the last autoscroll tick, and the time when the pointer entered the zone.
    var autoscrollTimes: (last: Double, zone: Double?)?
    /// The origin at the start of a live scroll (a scroller knob drag, a trackpad gesture): until
    /// its end, no page turns. ponytail: a start with no end stops the page turns until the next
    /// end; the app checks showed each start with its end (wheel, trackpad, knob).
    private(set) var liveScrollOrigin: Double?

    /// `headerWidth` is the width of the track headers at open.
    init(model: SessionWindow, studio: Studio, headerWidth: HeaderWidth = .standard) {
        self.model = model
        self.studio = studio
        ruler = TimelineRuler(model: model)
        super.init(frame: .zero)
        lanes.studio = studio
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
        NotificationCenter.default.addObserver(
            self, selector: #selector(liveScrollEnded), name: NSScrollView.didEndLiveScrollNotification,
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
        switch event {
        case .down(.lanes(let x, let y), _, _, _), .drag(.lanes(let x, let y)), .up(.lanes(let x, let y)):
            lanePoint = NSPoint(x: x, y: y)
        default: break
        }
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

    func context(_ inputs: LaneInputs) -> GestureContext? {
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
        lanes.showReadout(gesture.readout, at: lanePoint)
        // The strip shows the committed session, never a preview: it renders at the mouse-up.
        if !gesture.isActive, let source {
            let session = source.session
            overview?.inputs = OverviewInputs(
                session: session, selection: source.marks.selection(in: session)?.range,
                selectedLanes: session.tracks.indices.filter { source.marks.tracks.contains(session.tracks[$0].id) },
                extent: Viewport.extent(end: end(of: session), rate: session.sampleRate))
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
        if let viewport {
            overview?.show(viewport)
            // A session with no tracks shows no pane: its clamp of the origin is not a view to keep.
            if fitted, source?.session.tracks.isEmpty == false { model?.shownZoom = viewport.zoom }
        }
        publishVisible()
    }

    @objc private func liveScrollStarted() { liveScrollOrigin = origin }

    /// A live scroll that moved the view horizontally holds the follow; one with no move holds nothing.
    @objc private func liveScrollEnded() {
        if let start = liveScrollOrigin, origin != start { userScrolled() }
        liveScrollOrigin = nil
    }

    /// A user scroll that moves the view during play or a take holds the follow (decision 0017);
    /// the play goes on.
    func userScrolled() {
        guard let model, studio?.playback != .stopped || taking, !model.timeline.followHeld else { return }
        model.timeline.followHeld = true
    }

    /// A take records or finalizes: the last tick had a live head.
    var taking: Bool { last?.taking == true }

    /// The one head (F3): the record head of the last tick during a take, else the Studio playhead.
    var head: Frames {
        guard let last, last.taking else { return studio?.playhead ?? .zero }
        return Frames(Int(last.playhead))
    }

    /// The one end of the timeline (live take view, G3 and G4): the session end, or the held end
    /// when it is later. The lanes, the strip, and the viewport read it.
    func end(of session: Session) -> Frames { max(session.end, heldEnd ?? .zero) }

    /// A new held end: the lanes take their new width, and the strip its new extent and frame.
    func holdEnd(_ end: Frames?) {
        guard end != heldEnd else { return }
        heldEnd = end
        lanes.resize()
        redraw()
        viewMoved()
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

    /// One display tick: the record head during a take, else the playhead line between two
    /// polls, and the follow.
    func displayTick() {
        guard let studio else { return }
        let playback = studio.playback
        let head = studio.liveHead()
        let frame =
            head.map { Double($0.count) }
            ?? playheadFrame(
                polled: studio.playhead, at: studio.playheadTime, now: .now, playback: playback,
                rate: studio.session.sampleRate)
        tick(playhead: frame, playback: playback, taking: head != nil)
        autoscrollTick(at: CACurrentMediaTime())
        model?.loudnessTick(studio)
    }

    /// Moves the playhead line, or the record head line during a take (`taking`), and draws the
    /// live take. During play and during a take, the follow can turn the page. A play start, a
    /// take start, a shuttle change, or a move of the playhead while stopped with no take (a
    /// seek) ends a hold and shows the head when it is off the page. A head move in a take is not
    /// a seek. The end of a take (the hand-off or a finalize error) moves only the line and keeps
    /// the view. The first tick only takes the state.
    func tick(playhead: Double, playback: Playback, taking: Bool = false) {
        let previous = last
        last = (playhead, playback, taking)
        if taking, let rate = source?.session.sampleRate {
            // The lanes grow a minute at a time, before the follow, so each turn has room.
            let minute = 60 * rate
            holdEnd(Frames((Int(playhead + visibleFrames) / minute + 1) * minute))
        } else if previous?.taking == true {
            // The session can end before the right edge: keep it, so the clip view keeps the origin.
            holdEnd(Frames(Int(origin + visibleFrames)))
        }
        lanes.movePlayhead(to: playhead)
        overview?.movePlayhead(to: playhead)
        liveTick(head: taking ? Frames(Int(playhead)) : nil)
        guard let model, let previous, taking || !previous.taking else { return }
        let started = taking ? !previous.taking : playback != .stopped && playback != previous.playback
        let seeked = !taking && playback == .stopped && playhead != previous.playhead
        guard taking || playback != .stopped || seeked else { return }
        var state = model.timeline
        if started || seeked { state.followHeld = false }
        let direction: Shuttle.Direction
        if case .playing(let shuttle) = playback { direction = shuttle.direction } else { direction = .forward }
        let turn = state.follow(
            playhead: Frames(Int(playhead)), origin: origin, frames: visibleFrames, direction: direction)
        // Only a change: a write of the model makes SwiftUI update the views that read it.
        if state.followHeld != model.timeline.followHeld { model.timeline.followHeld = state.followHeld }
        if state.headLeftView != model.timeline.headLeftView { model.timeline.headLeftView = state.headLeftView }
        if let turn, liveScrollOrigin == nil { scroll(toFrame: turn) }
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
