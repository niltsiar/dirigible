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
    /// An event of the inspector handle. A drag moves the guide line, the up sets and saves a
    /// changed width, Esc gives the start width, and a double-click gives 270 pt (0023). Fallback 1
    /// of 0023: a live width missed the 16 ms budget at 2 h (p95 26 ms, C16), so the pane and the
    /// lanes keep their width until the up.
    func dragInspector(_ event: PaneDragEvent) {
        // A down first commits the typed text and ends the text focus, as the header handle does:
        // a focused field takes Esc. A drag with no mouse-up leaves an old target: drop it.
        if case .down = event {
            endNameEdit()
            inspectorPreview = nil
        }
        guard let step = inspectorDrag.handle(event, width: inspectorPreview ?? inspectorWidth) else { return }
        if inspectorDrag.isActive {
            inspectorPreview = fitted(step.width)
        } else {
            inspectorPreview = nil
            setInspectorWidth(step.width, save: step.save)
        }
        showInspectorGuide()
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

    /// The width inside the room of the window, its content width minus the lanes minimum: the
    /// minimum frame follows the width, so a wider pane would widen the window.
    private func fitted(_ width: InspectorWidth) -> InspectorWidth {
        let room = window.map { Double($0.contentLayoutRect.width) - SessionView.minWidth } ?? .infinity
        return InspectorWidth(min(width.points, room))
    }

    private func setInspectorWidth(_ width: InspectorWidth, save: Bool) {
        // The same width writes nothing: an Observation write runs the bodies also for an equal value.
        let width = fitted(width)
        if width != inspectorWidth { inspectorWidth = width }
        if save { app?.defaults?.set(inspectorWidth.points, forKey: InspectorWidth.defaultsKey) }
    }

    /// The 1 pt accent line at the target edge, over the window content; nil removes it. A Core
    /// Animation layer: a move runs no SwiftUI body and draws no lanes.
    private func showInspectorGuide() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let content = window?.contentView, let layer = content.layer, let preview = inspectorPreview else {
            inspectorGuide.removeFromSuperlayer()
            return
        }
        if inspectorGuide.superlayer !== layer { layer.addSublayer(inspectorGuide) }
        inspectorGuide.zPosition = 100
        content.effectiveAppearance.performAsCurrentDrawingAppearance {
            inspectorGuide.backgroundColor = NSColor.controlAccentColor.cgColor
        }
        inspectorGuide.frame = CGRect(
            x: content.bounds.width - preview.points, y: 0, width: 1, height: content.bounds.height)
    }
}
