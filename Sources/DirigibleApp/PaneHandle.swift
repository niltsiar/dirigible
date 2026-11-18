import AppKit
import DirigibleTimeline
import SwiftUI

/// The window edge that a pane sits at. The index grows to the right from the leading edge, so the
/// pointer x of the window is its width. The inspector grows to the left from the trailing edge.
enum PaneEdge {
    case leading, trailing
}

/// The state of one pane resize (decision 0023): the drag, the target of the drag, and the guide
/// line. Not observed: a drag event runs no SwiftUI body (C16).
@MainActor final class PaneResize<Width: PaneWidth> {
    private(set) var drag = PaneDrag<Width>()
    /// The fitted width that the pointer asks for, and the width that the guide shows (the request
    /// before the pane minimum of its tab). Nil when idle or before the first drag. The up saves
    /// the request.
    private(set) var target: (request: Width, preview: Width)?
    /// The line at the target edge during a drag, over the window content.
    let guide = CALayer()

    var preview: Width? { target?.preview }

    /// One event of the handle. A down drops the old target that a lost mouse-up leaves. A drag
    /// sets the target from `aim`. A press that ended clears the target: the caller applies the
    /// step when `drag.isActive` is false.
    func step(
        _ event: PaneDragEvent, start: Width, aim: (Width) -> (request: Width, preview: Width)
    ) -> PaneDragStep<Width>? {
        if case .down = event { target = nil }
        guard let step = drag.handle(event, width: target?.request ?? start) else { return nil }
        if drag.isActive {
            // The guide shows from the first drag, so a click shows no line.
            if case .drag = event { target = aim(step.width) }
        } else {
            target = nil
        }
        return step
    }
}

/// The 6 pt hit area over the divider of a pane (decision 0023): the drag, the double-click, the
/// cursor, and the AX splitter of the pane width.
struct PaneHandle: NSViewRepresentable {
    let model: SessionWindow
    let edge: PaneEdge

    func makeNSView(context: Context) -> PaneHandleView {
        let view = PaneHandleView(edge: edge)
        view.model = model
        return view
    }

    func updateNSView(_ view: PaneHandleView, context: Context) { view.model = model }
}

final class PaneHandleView: NSView {
    weak var model: SessionWindow?
    let edge: PaneEdge

    init(edge: PaneEdge) {
        self.edge = edge
        super.init(frame: .zero)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("PaneHandleView has no coder") }

    /// The pointer x grows toward a wider pane: the window x for the leading pane, minus the window
    /// x for the trailing pane (the column origin moves with the width).
    private func x(_ event: NSEvent) -> Double {
        edge == .leading ? Double(event.locationInWindow.x) : -Double(event.locationInWindow.x)
    }

    private func send(_ event: PaneDragEvent) {
        switch edge {
        case .leading: model?.dragIndex(event)
        case .trailing: model?.dragInspector(event)
        }
    }

    private func step(by points: Double) {
        switch edge {
        case .leading: model?.stepIndex(by: points)
        case .trailing: model?.stepInspector(by: points)
        }
    }

    override func mouseDown(with event: NSEvent) { send(.down(x: x(event), clicks: event.clickCount)) }
    override func mouseDragged(with event: NSEvent) { send(.drag(x: x(event))) }
    override func mouseUp(with event: NSEvent) { send(.up) }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .splitter }
    override func accessibilityLabel() -> String? {
        (edge == .leading ? L10n.indexHandle : L10n.inspectorHandle).text
    }
    override func accessibilityValue() -> Any? {
        edge == .leading ? model?.shownIndexWidth : model?.shownInspectorWidth
    }

    override func accessibilityPerformIncrement() -> Bool {
        step(by: 20)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        step(by: -20)
        return true
    }
}

extension SessionWindow {
    /// The 1 pt accent line at the target edge, over the window content; nil removes it. A Core
    /// Animation layer: a move runs no SwiftUI body and draws no lanes.
    func showGuide<Width: PaneWidth>(_ resize: PaneResize<Width>, edge: PaneEdge) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let guide = resize.guide
        guard let content = window?.contentView, let layer = content.layer, let preview = resize.preview else {
            guide.removeFromSuperlayer()
            return
        }
        if guide.superlayer !== layer {
            layer.addSublayer(guide)
            guide.zPosition = 100
            content.effectiveAppearance.performAsCurrentDrawingAppearance {
                guide.backgroundColor = NSColor.controlAccentColor.cgColor
            }
        }
        let x = edge == .leading ? preview.points : content.bounds.width - preview.points
        guide.frame = CGRect(x: x, y: 0, width: 1, height: content.bounds.height)
    }
}
