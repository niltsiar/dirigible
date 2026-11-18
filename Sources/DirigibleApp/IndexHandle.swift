import AppKit
import DirigibleTimeline

extension SessionWindow {
    /// An event of the index handle, as `dragInspector(_:)`: a drag moves the guide line, the up
    /// sets and saves a changed width, Esc gives the start width, and a double-click gives 240 pt.
    func dragIndex(_ event: PaneDragEvent) {
        let pane = leadingPane
        if case .down = event { endNameEdit() }
        guard let step = pane.resize.step(event, start: pane.width, aim: { (fitted($0), fitted($0)) }) else { return }
        if !pane.resize.drag.isActive { setIndexWidth(step.width, save: step.save) }
        showGuide(pane.resize, edge: .leading)
    }

    /// Esc: true when an index drag ran and Esc ended it with the start width.
    func cancelIndexDrag() -> Bool {
        guard leadingPane.resize.drag.isActive else { return false }
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
}
