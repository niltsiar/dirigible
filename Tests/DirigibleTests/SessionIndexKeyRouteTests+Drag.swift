import AppKit
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The index handle, as the inspector handle has it (`InspectorTests+Width.swift`): the guide at
/// the left edge, the double-click, the AX step, a lost mouse-up, and the room beside the inspector.
extension SessionIndexKeyRouteTests {
    func indexHandle(_ window: NSWindow) throws -> PaneHandleView {
        window.contentView?.layoutSubtreeIfNeeded()
        return try #require(
            windows.views(PaneHandleView.self, in: window.contentView).first { $0.edge == .leading }, "no index handle")
    }

    func pointer(_ type: NSEvent.EventType, _ x: Double, _ window: NSWindow, clicks: Int = 1) throws -> NSEvent {
        try #require(
            NSEvent.mouseEvent(
                with: type, location: NSPoint(x: x, y: window.contentLayoutRect.midY), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks,
                pressure: 1))
    }

    /// One drag of the index handle from its middle by `dx` window points (plus is wider).
    func dragIndexHandle(_ window: NSWindow, by dx: Double, up: Bool = true) throws {
        let view = try indexHandle(window)
        let x = Double(view.convert(view.bounds, to: nil).midX)
        view.mouseDown(with: try pointer(.leftMouseDown, x, window))
        view.mouseDragged(with: try pointer(.leftMouseDragged, x + dx, window))
        if up { view.mouseUp(with: try pointer(.leftMouseUp, x + dx, window)) }
    }

    @Test func aDragMovesTheGuideAtTheLeftEdge() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, _, window) = try await windows.open()
        await windows.paneSize(window, to: 1180)
        let view = try indexHandle(window)
        let x = Double(view.convert(view.bounds, to: nil).midX)
        view.mouseDown(with: try pointer(.leftMouseDown, x, window))
        #expect(model.leadingPane.resize.guide.superlayer == nil, "the guide shows at the first drag, not at the down")
        for dx in [20.0, 60, 100, -40] {
            view.mouseDragged(with: try pointer(.leftMouseDragged, x + dx, window))
            let guide = model.leadingPane.resize.guide
            #expect(guide.superlayer != nil && guide.superlayer === window.contentView?.layer, "dx \(dx): no guide")
            let target = min(400, max(240, 240 + dx))
            #expect(abs(Double(guide.frame.minX) - target) <= 0.5, "dx \(dx): guide at \(guide.frame)")
            #expect(model.leadingPane.width == .standard, "dx \(dx): the pane keeps 240 pt")
        }
        view.mouseUp(with: try pointer(.leftMouseUp, x - 40, window))
        #expect(model.leadingPane.resize.guide.superlayer == nil, "the up removes the guide")
        await model.close()
    }

    @Test func aDoubleClickGivesTheStandardWidthAndSaves() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, _, window) = try await windows.open()
        await windows.paneSize(window, to: 1180)
        try dragIndexHandle(window, by: 60)
        #expect(model.leadingPane.width.points == 300 && windows.defaults.double(forKey: IndexWidth.defaultsKey) == 300)
        let view = try indexHandle(window)
        let x = Double(view.convert(view.bounds, to: nil).midX)
        view.mouseDown(with: try pointer(.leftMouseDown, x, window, clicks: 2))
        #expect(model.leadingPane.width.points == 240, "a double-click gives 240 pt")
        #expect(windows.defaults.object(forKey: IndexWidth.defaultsKey) as? Double == 240, "and saves it")
        await model.close()
    }

    @Test func anAXStepDuringADragEndsTheDrag() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, _, window) = try await windows.open()
        await windows.paneSize(window, to: 1180)
        try dragIndexHandle(window, by: 100, up: false)
        let view = try indexHandle(window)
        #expect(view.accessibilityPerformIncrement())
        #expect(
            model.leadingPane.width.points == 260 && !model.leadingPane.resize.drag.isActive, "the step ends the drag")
        #expect(model.leadingPane.resize.guide.superlayer == nil, "the step removes the guide")
        view.mouseUp(with: try pointer(.leftMouseUp, 0, window))
        #expect(model.leadingPane.width.points == 260, "the up keeps the step: \(model.leadingPane.width.points)")
        await model.close()
    }

    @Test func aLostMouseUpLeavesNoDrag() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, _, window) = try await windows.open()
        await windows.paneSize(window, to: 1180)
        try dragIndexHandle(window, by: 100, up: false)
        model.toggleIndex()
        let pane = model.leadingPane
        #expect(!pane.resize.drag.isActive && pane.resize.preview == nil, "a hide ends the drag")
        #expect(pane.resize.guide.superlayer == nil, "a hide removes the guide")
        model.toggleIndex()
        await until("the index shows again") {
            window.contentView?.layoutSubtreeIfNeeded()
            return pane.shown && pane.table != nil
        }
        try dragIndexHandle(window, by: 100, up: false)
        try dragIndexHandle(window, by: 30)
        #expect(pane.width.points == 270, "the down starts from 240 pt: \(pane.width.points)")
        await model.close()
    }

    @Test func aDoubleClickInANarrowWindowSavesTheStandardWidth() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, _, window) = try await windows.open()
        model.toggleInspector()
        model.inspectorWidth = InspectorWidth(270)
        model.leadingPane.width = IndexWidth(300)
        await windows.paneSize(window, to: 1290)
        let view = try indexHandle(window)
        let x = Double(view.convert(view.bounds, to: nil).midX)
        view.mouseDown(with: try pointer(.leftMouseDown, x, window, clicks: 2))
        #expect(model.leadingPane.width.points == 240, "the room of a 1290 pt window with the inspector")
        #expect(
            windows.defaults.object(forKey: IndexWidth.defaultsKey) as? Double == 240, "the double-click saves 240 pt")
        await model.close()
    }

    /// The inspector shows 320 pt on the Transcript tab, not its saved 270 pt: the index drag fits
    /// beside the shown width, so the window keeps its width.
    @Test func anIndexDragFitsBesideTheTranscriptMinimum() async throws {
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, _, window) = try await windows.open()
        await windows.paneSize(window, to: 1300)
        model.toggleInspector()
        model.inspectorWidth = InspectorWidth(270)
        model.selectInspectorTab(.transcript)
        try #require(model.shownInspectorWidth == 320)
        model.dragIndex(.down(x: 240, clicks: 1))
        model.dragIndex(.drag(x: 600))
        model.dragIndex(.up)
        #expect(model.leadingPane.width.points == 260, "the index stops at 1300 - 720 - 320")
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(window.contentLayoutRect.width == 1300, "no pane widened the window")
        await model.close()
    }
}
