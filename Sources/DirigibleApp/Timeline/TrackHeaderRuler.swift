import AppKit
import DirigibleCore
import DirigibleTimeline
import SwiftUI

/// The track headers left of the lanes (decision 0017): SwiftUI rows in the vertical ruler of the
/// scroll view. The top of the clip view places them, so row n stays beside lane n in a vertical
/// scroll. A wheel over them goes up the responder chain to the scroll view. A handle at the
/// trailing edge sets the width (decision 0023). The ruler is opaque: the lanes under it never show
/// (the user report L5), and a 1 pt separator line marks its trailing edge.
final class TrackHeaderRuler: NSRulerView {
    let host = HeaderHost(rootView: AnyView(EmptyView()))
    let handle = HeaderHandle()
    /// Saves the width at the mouse-up, a double-click, and an AX step. Nil: no save.
    var save: ((HeaderWidth) -> Void)?
    /// The calls of `layout()`, for the bench (probe Q4).
    private(set) var layouts = 0
    private var drag = HeaderDrag()
    /// The document y at the top of the clip view, and the height of all lanes.
    private var rows: (top: CGFloat, height: CGFloat) = (0, 0)
    private let edge = CALayer()

    /// The width applies at once: the scroll view tiles, and the lanes take the new width.
    var width = HeaderWidth.standard {
        didSet {
            guard width != oldValue else { return }
            ruleThickness = width.points
            scrollView?.tile()
            needsLayout = true
        }
    }

    init() {
        super.init(scrollView: nil, orientation: .verticalRuler)
        ruleThickness = width.points
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
        // macOS 14 does not clip subviews by default: a row above the lanes would cover the ruler.
        clipsToBounds = true
        wantsLayer = true
        edge.actions = ["position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull()]
        edge.zPosition = 1
        layer?.addSublayer(edge)
        host.sizingOptions = []
        addSubview(host)
        addSubview(handle)
        handle.ruler = self
    }

    required init(coder: NSCoder) { fatalError("no coder") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    /// The fill and the edge line in the colors of the effective appearance.
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            edge.backgroundColor = NSColor.separatorColor.cgColor
        }
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {}

    /// A ruler gives the accessibility tree only its markers, so VoiceOver did not reach the rows and
    /// the handle, which are subviews (Phase 7, the tree of the app).
    override func accessibilityChildren() -> [Any]? { (super.accessibilityChildren() ?? []) + [host, handle] }

    override func layout() {
        layouts += 1
        super.layout()
        placeRows()
        handle.frame = NSRect(x: width.points - 6, y: 0, width: 6, height: bounds.height)
        edge.frame = CGRect(x: width.points - 1, y: 0, width: 1, height: bounds.height)
    }

    /// `top` is the document y at the top of the clip view; `height` is the height of all lanes.
    func place(top: CGFloat, height: CGFloat) {
        rows = (top, height)
        placeRows()
    }

    /// During a drag the rows keep the start width and the ruler clips them: a layout of the rows at
    /// each event missed the 16 ms budget (0023 fallback 2, run 1b slice 5). They take the width at
    /// the mouse-up, Esc, a double-click, and an AX step.
    private func placeRows() {
        let frame = NSRect(x: 0, y: -rows.top, width: (drag.start ?? width).points, height: rows.height)
        if host.frame != frame { host.frame = frame }
    }

    /// A handle event. A mouse-down first commits the typed track names and ends the text focus,
    /// as a lane mouse-down does, so Esc reaches the window.
    func dragged(_ event: HeaderDragEvent) {
        if case .down = event { endTextEdit() }
        guard let step = drag.handle(event, width: width) else { return }
        width = step.width
        placeRows()
        if step.save { save?(width) }
    }

    /// Commits the typed track names and ends the text focus, as a lane mouse-down does: a focused
    /// field takes Esc, and an AX step gives the rows a new width at once.
    private func endTextEdit() {
        (scrollView as? TimelineScrollView)?.model?.endNameEdit()
    }

    /// Esc: true when a header drag ran and Esc ended it with the start width.
    func cancelDrag() -> Bool {
        guard drag.isActive else { return false }
        dragged(.escape)
        return true
    }

    /// An AX increment or decrement: 20 pt, clamped, saved.
    func step(by points: Double) {
        endTextEdit()
        width = HeaderWidth(width.points + points)
        save?(width)
    }
}

/// The host of the header rows. It keeps each mouse-down for the window: a SwiftUI tap gives no
/// event, so a header tap reads the modifier keys of this event. The second click of a
/// double-click on a name starts the rename here, and SwiftUI does not get it: a SwiftUI double
/// tap read the time between the clicks, and the SwiftUI end of a click on a row could take the
/// text focus from the new rename. Both made a test flaky under load.
final class HeaderHost: NSHostingView<AnyView> {
    /// True from a mouse-down that this view took to its mouse-up.
    private var tookDown = false

    override func mouseDown(with event: NSEvent) {
        let model = ((superview as? TrackHeaderRuler)?.scrollView as? TimelineScrollView)?.model
        model?.headerMouseDown = event
        if event.clickCount == 2, !event.modifierFlags.contains(.control), let model,
            let track = nameTrack(event, model)
        {
            tookDown = true
            model.startRename(track)
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard !tookDown else {
            tookDown = false
            return
        }
        super.mouseUp(with: event)
    }

    /// The track of the name field under `event`. Nil when the point is not on a name field.
    private func nameTrack(_ event: NSEvent, _ model: SessionWindow) -> TrackID? {
        let rows = nameFields
        let point = convert(event.locationInWindow, from: nil)
        guard let tracks = model.studio?.session.tracks, rows.count == tracks.count,
            let row = rows.firstIndex(where: { $0.convert($0.bounds, to: self).contains(point) })
        else { return nil }
        return tracks[row].id
    }

    /// The name fields in row order: row n is track n of the session.
    private var nameFields: [NSTextField] {
        func fields(_ view: NSView) -> [NSTextField] {
            if let field = view as? NSTextField, field.isEditable { return [field] }
            return view.subviews.flatMap(fields)
        }
        return fields(self).sorted { $0.convert($0.bounds, to: self).minY < $1.convert($1.bounds, to: self).minY }
    }

    /// Gives the text focus to the name field of `row`, once. A SwiftUI focus request could come
    /// twice under load, and the second one ended the edit of the first: the window took the focus.
    func focusName(row: Int) {
        let rows = nameFields
        guard rows.indices.contains(row), (window?.firstResponder as? NSTextView)?.delegate !== rows[row] else {
            return
        }
        window?.makeFirstResponder(rows[row])
    }
}

/// The 6 pt hit area at the trailing edge of the headers, above the rows: the drag, the
/// double-click, the cursor, and the AX splitter of the header width.
final class HeaderHandle: NSView {
    weak var ruler: TrackHeaderRuler?

    private func x(_ event: NSEvent) -> Double { Double(ruler?.convert(event.locationInWindow, from: nil).x ?? 0) }

    override func mouseDown(with event: NSEvent) { ruler?.dragged(.down(x: x(event), clicks: event.clickCount)) }
    override func mouseDragged(with event: NSEvent) { ruler?.dragged(.drag(x: x(event))) }
    override func mouseUp(with event: NSEvent) { ruler?.dragged(.up) }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .splitter }
    override func accessibilityLabel() -> String? { L10n.headerHandle.text }
    override func accessibilityValue() -> Any? { ruler?.width.points }

    override func accessibilityPerformIncrement() -> Bool {
        ruler?.step(by: 20)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        ruler?.step(by: -20)
        return true
    }
}
