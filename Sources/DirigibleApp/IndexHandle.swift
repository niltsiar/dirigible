import AppKit
import DirigibleTimeline
import SwiftUI

/// The 6 pt hit area over the index divider (decision 0023): the drag, the double-click, the
/// cursor, and the AX splitter of the index width, as the inspector handle. The index grows to the
/// right, so the pointer x of the window is the width.
struct IndexHandle: NSViewRepresentable {
    let model: SessionWindow

    func makeNSView(context: Context) -> IndexHandleView {
        let view = IndexHandleView()
        view.model = model
        return view
    }

    func updateNSView(_ view: IndexHandleView, context: Context) { view.model = model }
}

final class IndexHandleView: NSView {
    weak var model: SessionWindow?

    private func x(_ event: NSEvent) -> Double { Double(event.locationInWindow.x) }

    override func mouseDown(with event: NSEvent) { model?.dragIndex(.down(x: x(event), clicks: event.clickCount)) }
    override func mouseDragged(with event: NSEvent) { model?.dragIndex(.drag(x: x(event))) }
    override func mouseUp(with event: NSEvent) { model?.dragIndex(.up) }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .splitter }
    override func accessibilityLabel() -> String? { L10n.indexHandle.text }
    override func accessibilityValue() -> Any? { model?.shownIndexWidth }

    override func accessibilityPerformIncrement() -> Bool {
        model?.stepIndex(by: 20)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        model?.stepIndex(by: -20)
        return true
    }
}

extension SessionWindow {
    /// An event of the index handle, as `dragInspector(_:)`: a drag moves the guide line, the up
    /// sets and saves a changed width, Esc gives the start width, and a double-click gives 240 pt.
    func dragIndex(_ event: PaneDragEvent) {
        let pane = leadingPane
        if case .down = event {
            endNameEdit()
            pane.preview = nil
            pane.request = nil
        }
        guard let step = pane.drag.handle(event, width: pane.request ?? pane.width) else { return }
        if pane.drag.isActive {
            if case .drag = event {
                pane.request = fitted(step.width)
                pane.preview = fitted(step.width)
            }
        } else {
            pane.preview = nil
            pane.request = nil
            setIndexWidth(step.width, save: step.save)
        }
        showIndexGuide()
    }

    /// Esc: true when an index drag ran and Esc ended it with the start width.
    func cancelIndexDrag() -> Bool {
        guard leadingPane.drag.isActive else { return false }
        dragIndex(.escape)
        return true
    }

    /// An AX step of the splitter. A step ends a pointer drag first, so the later mouse-up does
    /// not undo the step.
    func stepIndex(by points: Double) {
        _ = cancelIndexDrag()
        setIndexWidth(fitted(IndexWidth(shownIndexWidth + points)), save: true)
    }

    /// The width inside the room of the window: its content width minus the lanes minimum and the
    /// shown inspector. The minimum frame follows the width, so a wider pane would widen the window.
    func fitted(_ width: IndexWidth) -> IndexWidth {
        let inspector = showsInspector ? shownInspectorWidth : 0
        let room = window.map { Double($0.contentLayoutRect.width) - SessionView.minWidth - inspector } ?? .infinity
        return IndexWidth(min(width.points, room))
    }

    /// Shows the request fitted to the room, and saves the request: a double-click in a narrow
    /// window saves the standard width.
    private func setIndexWidth(_ request: IndexWidth, save: Bool) {
        let width = fitted(request)
        if width != leadingPane.width { leadingPane.width = width }
        if save { app?.defaults?.set(request.points, forKey: IndexWidth.defaultsKey) }
    }

    /// The 1 pt accent line at the target edge, over the window content; nil removes it. A Core
    /// Animation layer: a move runs no SwiftUI body and draws no lanes.
    private func showIndexGuide() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let guide = leadingPane.guide
        guard let content = window?.contentView, let layer = content.layer, let preview = leadingPane.preview else {
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
        guide.frame = CGRect(x: preview.points, y: 0, width: 1, height: content.bounds.height)
    }
}
