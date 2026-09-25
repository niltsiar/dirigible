import AppKit
import DirigibleAudio
import DirigibleCore
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

    func makeNSView(context: Context) -> TimelineScrollView {
        let view = TimelineScrollView(model: model, studio: studio)
        model.timelineView = view
        return view
    }

    func updateNSView(_ view: TimelineScrollView, context: Context) {
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
    /// The calls of `updateNSView`, for criterion 24.
    var updates = 0
    /// The target of the display link; the link retains it, and it holds this view weakly.
    private(set) var linkProxy: DisplayLinkProxy?
    private var link: CADisplayLink?
    /// The playhead and the playback of the last tick.
    private var last: (playhead: Double, playback: Playback)?
    /// Zoom to Session at the first layout with a width.
    private var fitted = false

    init(model: SessionWindow, studio: Studio) {
        self.model = model
        self.studio = studio
        ruler = TimelineRuler(model: model)
        super.init(frame: .zero)
        hasHorizontalScroller = true
        hasVerticalScroller = true
        backgroundColor = .windowBackgroundColor
        documentView = lanes
        lanes.model = model
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

    func update(_ inputs: LaneInputs) {
        lanes.inputs = inputs
        ruler.inputs = RulerInputs(
            markers: inputs.session.markers, marks: inputs.marks, scale: inputs.scale, rate: inputs.session.sampleRate)
        fitOnce()
        viewMoved()
    }

    override func tile() {
        super.tile()
        lanes.resize()
        fitOnce()
        viewMoved()
    }

    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        viewMoved()
    }

    /// The one vertical origin, the top of the clip view, places the headers beside the lanes
    /// and gives the lanes in view. The header ruler and the clip view have the same top.
    private func viewMoved() {
        headers.place(top: contentView.bounds.minY, height: lanes.frame.height)
        publishVisible()
    }

    // MARK: Zoom

    /// The zoom by `factor` at `x` points from the left edge (the pointer), or with no `x` at the
    /// anchor of the keys: the playhead when it is in view, else the view center.
    func zoom(by factor: Double, at x: Double? = nil) {
        guard let inputs = lanes.inputs, let studio else { return }
        let width = Double(shown.width)
        let anchor =
            x.map { (frame: Frames(Int(origin + $0 * framesPerPoint)), x: $0) }
            ?? zoomAnchor(playhead: studio.playhead, origin: origin, width: width, scale: inputs.scale)
        let zoomed = inputs.scale.zoomed(by: factor, anchor: anchor.frame, at: anchor.x, limits: limits(inputs))
        show(zoomed.scale, origin: zoomed.origin)
    }

    /// Zoom to Session: 0 to the end + 2%.
    func zoomToSession() {
        guard let inputs = lanes.inputs else { return }
        let end = inputs.session.end
        show(TimelineScale.fit(end: end, width: Double(shown.width), limits: limits(inputs)), origin: 0)
    }

    /// Zoom to Selection: the range with 5% on each side. With no selection, nothing.
    func zoomToSelection() {
        guard let inputs = lanes.inputs, let selection = model?.timeline.marks.selection(in: inputs.session) else {
            return
        }
        let fit = TimelineScale.fit(selection.range, width: Double(shown.width), limits: limits(inputs))
        show(fit.scale, origin: fit.origin)
    }

    private func limits(_ inputs: LaneInputs) -> ClosedRange<Double> {
        TimelineScale.limits(
            end: inputs.session.end, rate: inputs.session.sampleRate, width: Double(shown.width))
    }

    /// Sets the scale here and in the window model, then scrolls: the document view has its new
    /// width before the scroll, and the SwiftUI update after it gives equal inputs.
    private func show(_ scale: TimelineScale, origin: Double) {
        guard var inputs = lanes.inputs else { return }
        if model?.timeline.scale != scale { model?.timeline.scale = scale }
        inputs.scale = scale
        update(inputs)
        scroll(toFrame: origin)
    }

    private func fitOnce() {
        guard !fitted, lanes.inputs != nil, shown.width > 0 else { return }
        fitted = true
        zoomToSession()
    }

    /// Automatic Scroll turned on: the page of the playhead, with the playhead at 11%.
    func showPlayhead() {
        guard let studio,
            let turn = followOrigin(
                playhead: studio.playhead, origin: origin, frames: visibleFrames, direction: .forward)
        else { return }
        scroll(toFrame: turn)
    }

    /// A horizontal scroll that puts `origin` at the left edge of the lanes in view. The vertical
    /// origin stays.
    func scroll(toFrame origin: Double) {
        contentView.scroll(
            to: NSPoint(x: origin / framesPerPoint - contentView.contentInsets.left, y: contentView.bounds.minY))
        reflectScrolledClipView(contentView)
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else {
            super.scrollWheel(with: event)
            userScrolled()
            return
        }
        let dy = Double(event.scrollingDeltaY)
        zoom(by: pow(2, event.hasPreciseScrollingDeltas ? -dy / 40 : -dy), at: pointer(event))
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 - Double(event.magnification), at: pointer(event))
    }

    private func pointer(_ event: NSEvent) -> Double {
        Double(contentView.convert(event.locationInWindow, from: nil).x - shown.minX)
    }

    @objc private func liveScrollStarted() { userScrolled() }

    /// A user scroll during play holds the follow (decision 0017); the play goes on.
    private func userScrolled() {
        guard let model, studio?.playback != .stopped, !model.timeline.followHeld else { return }
        model.timeline.followHeld = true
    }

    /// The frames and the whole lanes in view, for the record-over warning. It writes only a
    /// change, so a tick that does not scroll updates no SwiftUI view.
    private func publishVisible() {
        guard let model, let inputs = lanes.inputs, shown.width > 0 else { return }
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
    }

    /// Moves the playhead line. During play, the follow can turn the page. A play start, a
    /// shuttle change, or a move of the playhead while stopped (a seek) ends a hold and shows
    /// the playhead when it is off the page. The first tick only takes the state.
    func tick(playhead: Double, playback: Playback) {
        lanes.movePlayhead(to: playhead)
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

/// The track headers left of the lanes (decision 0017): SwiftUI rows in the vertical ruler of the
/// scroll view. The top of the clip view places them, so row n stays beside lane n in a vertical
/// scroll. A wheel over them goes up the responder chain to the scroll view.
final class TrackHeaderRuler: NSRulerView {
    static let width: CGFloat = 340
    let host = NSHostingView(rootView: AnyView(EmptyView()))

    init() {
        super.init(scrollView: nil, orientation: .verticalRuler)
        ruleThickness = Self.width
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
        // macOS 14 does not clip subviews by default: a row above the lanes would cover the ruler.
        clipsToBounds = true
        host.sizingOptions = []
        addSubview(host)
    }

    required init(coder: NSCoder) { fatalError("no coder") }

    override var isFlipped: Bool { true }

    override func drawHashMarksAndLabels(in rect: NSRect) {}

    /// `top` is the document y at the top of the clip view; `height` is the height of all lanes.
    func place(top: CGFloat, height: CGFloat) {
        let frame = NSRect(x: 0, y: -top, width: Self.width, height: height)
        if host.frame != frame { host.frame = frame }
    }
}
