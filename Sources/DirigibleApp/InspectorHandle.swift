import AppKit
import DirigibleTimeline
import SwiftUI

/// The 6 pt hit area over the inspector divider (decision 0023): the drag, the double-click, the
/// cursor, and the AX splitter of the inspector width, as the header handle.
struct InspectorHandle: NSViewRepresentable {
    let model: SessionWindow

    func makeNSView(context: Context) -> InspectorHandleView {
        let view = InspectorHandleView()
        view.model = model
        return view
    }

    func updateNSView(_ view: InspectorHandleView, context: Context) { view.model = model }
}

final class InspectorHandleView: NSView {
    weak var model: SessionWindow?

    /// Minus the window x: the column origin moves with the width, and the pane grows to the left.
    private func x(_ event: NSEvent) -> Double { -Double(event.locationInWindow.x) }

    override func mouseDown(with event: NSEvent) { model?.dragInspector(.down(x: x(event), clicks: event.clickCount)) }
    override func mouseDragged(with event: NSEvent) { model?.dragInspector(.drag(x: x(event))) }
    override func mouseUp(with event: NSEvent) { model?.dragInspector(.up) }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .splitter }
    override func accessibilityLabel() -> String? { L10n.inspectorHandle.text }
    override func accessibilityValue() -> Any? { model?.inspectorWidth.points }

    override func accessibilityPerformIncrement() -> Bool {
        model?.stepInspector(by: 20)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        model?.stepInspector(by: -20)
        return true
    }
}

extension SessionWindow {
    /// An event of the inspector handle. A drag is live, the up saves a changed width, Esc gives
    /// the start width, and a double-click gives 270 pt (the header drag of 0023).
    func dragInspector(_ event: PaneDragEvent) {
        guard let step = inspectorDrag.handle(event, width: inspectorWidth) else { return }
        setInspectorWidth(step.width, save: step.save)
    }

    /// Esc: true when an inspector drag ran and Esc ended it with the start width.
    func cancelInspectorDrag() -> Bool {
        guard inspectorDrag.isActive else { return false }
        dragInspector(.escape)
        return true
    }

    /// An AX step of the splitter: the width changes and saves at once.
    func stepInspector(by points: Double) {
        setInspectorWidth(InspectorWidth(inspectorWidth.points + points), save: true)
    }

    /// The width stays inside the room of the window, its content width minus the lanes minimum:
    /// the minimum frame follows the width, so a wider pane would widen the window.
    private func setInspectorWidth(_ width: InspectorWidth, save: Bool) {
        let room = window.map { Double($0.contentLayoutRect.width) - SessionView.minWidth } ?? .infinity
        inspectorWidth = InspectorWidth(min(width.points, room))
        if save { app?.defaults?.set(inspectorWidth.points, forKey: InspectorWidth.defaultsKey) }
    }
}
