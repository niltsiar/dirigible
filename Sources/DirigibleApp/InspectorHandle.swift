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
    override func accessibilityValue() -> Any? { model?.shownInspectorWidth }

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
    /// lanes keep their width until the up. The press starts at the shown width, so the Transcript
    /// tab minimum never changes the saved width (P20).
    func dragInspector(_ event: PaneDragEvent) {
        // A down first commits the typed text and ends the text focus, as the header handle does:
        // a focused field takes Esc. A drag with no mouse-up leaves an old target: drop it.
        if case .down = event {
            endNameEdit()
            inspectorPreview = nil
            inspectorRequest = nil
        }
        let width = inspectorRequest ?? InspectorWidth(shownInspectorWidth)
        guard let step = inspectorDrag.handle(event, width: width) else { return }
        if inspectorDrag.isActive {
            // The guide shows from the first drag, so a click shows no line.
            if case .drag = event {
                inspectorRequest = fitted(step.width)
                inspectorPreview = atLeastTranscript(fitted(step.width))
            }
        } else {
            inspectorPreview = nil
            inspectorRequest = nil
            endInspectorDrag(event, step)
        }
        showInspectorGuide()
    }

    /// Sets the width of an ended press. A double-click gives the standard width; an up or Esc
    /// saves what `savedInspectorWidth(for:)` gives.
    private func endInspectorDrag(_ event: PaneDragEvent, _ step: PaneDragStep<InspectorWidth>) {
        guard case .down = event else {
            let width = savedInspectorWidth(for: step.width)
            return setInspectorWidth(width, save: step.save && width != inspectorWidth)
        }
        setInspectorWidth(step.width, save: step.save)
    }

    /// The one width rule of the drag and the step (0023). On the Transcript tab a request at or
    /// under 320 pt saves the lower of the saved width and 320 pt, so the minimum never raises the
    /// saved width; a request above 320 pt saves the request. Other tabs save the request.
    private func savedInspectorWidth(for request: InspectorWidth) -> InspectorWidth {
        let least = Self.transcriptMinimumWidth
        guard inspectorTab == .transcript, request.points <= least else { return request }
        return InspectorWidth(min(inspectorWidth.points, least))
    }

    /// Esc: true when an inspector drag ran and Esc ended it with the start width.
    func cancelInspectorDrag() -> Bool {
        guard inspectorDrag.isActive else { return false }
        dragInspector(.escape)
        return true
    }

    /// An AX step of the splitter: the shown width plus the step goes through
    /// `savedInspectorWidth(for:)` and saves at once. A step ends a pointer drag first, so the
    /// later mouse-up does not undo the step.
    func stepInspector(by points: Double) {
        _ = cancelInspectorDrag()
        setInspectorWidth(savedInspectorWidth(for: fitted(InspectorWidth(shownInspectorWidth + points))), save: true)
    }

    /// The target of a drag stops at 320 pt on the Transcript tab (P20).
    private func atLeastTranscript(_ width: InspectorWidth) -> InspectorWidth {
        inspectorTab == .transcript ? InspectorWidth(max(width.points, Self.transcriptMinimumWidth)) : width
    }

    /// The width inside the room of the window, its content width minus the lanes minimum: the
    /// minimum frame follows the width, so a wider pane would widen the window.
    private func fitted(_ width: InspectorWidth) -> InspectorWidth {
        let room = window.map { Double($0.contentLayoutRect.width) - SessionView.minWidth } ?? .infinity
        return InspectorWidth(min(width.points, room))
    }

    /// Shows the request fitted to the room, and saves the request: a double-click in a narrow
    /// window saves the standard width (0023). A drag and a step request a fitted width.
    private func setInspectorWidth(_ request: InspectorWidth, save: Bool) {
        // The same width writes nothing: an Observation write runs the bodies also for an equal value.
        let width = fitted(request)
        if width != inspectorWidth { inspectorWidth = width }
        if save { app?.defaults?.set(request.points, forKey: InspectorWidth.defaultsKey) }
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
        if inspectorGuide.superlayer !== layer {
            layer.addSublayer(inspectorGuide)
            inspectorGuide.zPosition = 100
            content.effectiveAppearance.performAsCurrentDrawingAppearance {
                inspectorGuide.backgroundColor = NSColor.controlAccentColor.cgColor
            }
        }
        inspectorGuide.frame = CGRect(
            x: content.bounds.width - preview.points, y: 0, width: 1, height: content.bounds.height)
    }
}
