import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The inspector handle (run ui-polish-chrome criteria C10 to C14): the drag, the clamp, the
/// preference, the window minimum, the double-click and Esc, and the AX splitter.
extension InspectorTests {
    func handle(_ window: NSWindow) throws -> InspectorHandleView {
        func find(_ view: NSView) -> InspectorHandleView? {
            view as? InspectorHandleView ?? view.subviews.lazy.compactMap(find).first
        }
        window.contentView?.layoutSubtreeIfNeeded()
        return try #require(window.contentView.flatMap(find), "no inspector handle")
    }

    /// A mouse event of the handle at window x `x`, at the middle height of the handle.
    func event(_ type: NSEvent.EventType, _ x: Double, _ window: NSWindow, clicks: Int = 1) throws -> NSEvent {
        try #require(
            NSEvent.mouseEvent(
                with: type, location: NSPoint(x: x, y: window.contentLayoutRect.midY), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks,
                pressure: 1))
    }

    /// One drag of the handle from its middle by `dx` window points (minus is wider).
    func drag(_ window: NSWindow, by dx: Double, up: Bool = true) throws {
        let view = try handle(window)
        let x = Double(view.convert(view.bounds, to: nil).midX)
        view.mouseDown(with: try event(.leftMouseDown, x, window))
        view.mouseDragged(with: try event(.leftMouseDragged, x + dx, window))
        if up { view.mouseUp(with: try event(.leftMouseUp, x + dx, window)) }
    }

    // MARK: C10

    /// C10: a drag sets the width, clamped to 240...400 pt and to the content width - 720 pt; the
    /// lanes and the pane give the content width.
    @Test func theInspectorWidthStaysIn240To400() async throws {
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let (model, _, window, _) = try await open(try await package())
        window.setContentSize(NSSize(width: 1180, height: 600))
        await until("the window takes 1180 pt") { window.contentLayoutRect.width == 1180 }
        for (request, expected) in [(239.0, 240.0), (240, 240), (300, 300), (400, 400), (401, 400), (100, 240)] {
            try drag(window, by: model.inspectorWidth.points - request)
            #expect(model.inspectorWidth.points == expected, "request \(request): \(model.inspectorWidth.points)")
            await until("the lanes give the pane its width") { layout(window) + expected == 1180 }
        }
        // A narrow window: the pane takes only the room, and the window keeps its width.
        model.inspectorWidth = .standard
        window.setContentSize(NSSize(width: 1000, height: 600))
        await until("the window takes 1000 pt") {
            window.contentView?.layoutSubtreeIfNeeded()
            return window.contentLayoutRect.width == 1000
        }
        try drag(window, by: 270 - 400)
        #expect(model.inspectorWidth.points == 280, "the room of a 1000 pt window: \(model.inspectorWidth.points)")
        try await Task.sleep(for: .milliseconds(200))
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(window.contentLayoutRect.width == 1000, "the window keeps its width: \(window.contentLayoutRect.width)")
        await model.close()
    }

    // MARK: C11

    /// C11: a new window takes the stored width, clamped; a drag event saves nothing and the
    /// mouse-up saves a changed width.
    @Test func aNewWindowTakesTheStoredWidth() async throws {
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        for (index, (stored, expected))
            in ([(nil, 270.0), (320.0, 320), (1000.0, 400), (-5.0, 240), ("320", 270)]
            as [(Any?, Double)]).enumerated()
        {
            defaults.set(stored, forKey: InspectorWidth.defaultsKey)
            let (model, _, _, _) = try await open(try await package("s\(index)"), shown: false)
            #expect(model.inspectorWidth.points == expected, "stored \(String(describing: stored))")
            await model.close()
        }
        defaults.removeObject(forKey: InspectorWidth.defaultsKey)
        let (model, _, window, _) = try await open(try await package("save"))
        window.setContentSize(NSSize(width: 1180, height: 600))
        await until("the window takes 1180 pt") { window.contentLayoutRect.width == 1180 }
        try drag(window, by: -30, up: false)
        #expect(model.inspectorPreview?.points == 300 && model.inspectorWidth == .standard)
        #expect(defaults.object(forKey: InspectorWidth.defaultsKey) == nil, "a drag event saves nothing")
        try handle(window).mouseUp(with: try event(.leftMouseUp, 0, window))
        #expect(model.inspectorWidth.points == 300 && model.inspectorPreview == nil, "the up sets the width")
        #expect(defaults.object(forKey: InspectorWidth.defaultsKey) as? Double == 300, "the up saves")
        await model.close()
    }

    // MARK: C12

    /// C12: the window minimum is 720 pt plus the width; a show widens a narrow window to it.
    @Test func showingAWidePaneWidensANarrowWindow() async throws {
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        defaults.set(400.0, forKey: InspectorWidth.defaultsKey)
        let (model, _, window, _) = try await open(try await package(), shown: false)
        window.setContentSize(NSSize(width: 500, height: 600))
        await until(limit: .seconds(10), "the window takes its minimum") { window.contentLayoutRect.width == 720 }
        model.toggleInspector()
        #expect(Double(window.contentLayoutRect.width) == 1120, "\(window.contentLayoutRect.width)")
        await model.close()
    }

    // MARK: C10 double-click and Esc

    /// The header drag of 0023 for the inspector: Esc gives the start width and saves nothing; a
    /// double-click gives 270 pt and saves it.
    @Test func aDoubleClickAndEscGiveTheStandardAndTheStartWidth() async throws {
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let (model, _, window, view) = try await open(try await package())
        window.setContentSize(NSSize(width: 1180, height: 600))
        await until("the window takes 1180 pt") { window.contentLayoutRect.width == 1180 }
        try drag(window, by: -100, up: false)
        #expect(model.inspectorPreview?.points == 370)
        #expect(window.firstResponder === view.lanes, "Esc goes to the window from the lanes")
        window.cancelOperation(nil)
        #expect(model.inspectorWidth.points == 270, "Esc gives the start width")
        #expect(model.inspectorPreview == nil && model.inspectorGuide.superlayer == nil, "Esc removes the guide")
        #expect(defaults.object(forKey: InspectorWidth.defaultsKey) == nil, "Esc saves nothing")
        #expect(!model.inspectorDrag.isActive)

        try drag(window, by: -60)
        #expect(model.inspectorWidth.points == 330)
        let handle = try handle(window)
        let x = Double(handle.convert(handle.bounds, to: nil).midX)
        handle.mouseDown(with: try event(.leftMouseDown, x, window, clicks: 2))
        #expect(model.inspectorWidth.points == 270, "a double-click gives 270 pt")
        #expect(defaults.object(forKey: InspectorWidth.defaultsKey) as? Double == 270, "and saves it")
        await model.close()
    }

    // MARK: C14

    /// C14: the handle is 6 pt wide over the divider and takes the hit 2 pt on each side; it is an
    /// AX splitter with 20 pt steps.
    @Test func theHandleTakesTheDragAndIsASplitter() async throws {
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let (model, _, window, _) = try await open(try await package())
        window.setContentSize(NSSize(width: 1180, height: 600))
        await until("the window takes 1180 pt") { window.contentLayoutRect.width == 1180 }
        let handle = try handle(window)
        var frame = NSRect.zero
        await until(limit: .seconds(10), "the handle sits on the divider at 910 pt") {
            window.contentView?.layoutSubtreeIfNeeded()
            frame = handle.convert(handle.bounds, to: nil)
            return abs(frame.midX - 910) <= 1
        }
        #expect(frame.width == 6, "\(frame)")
        for dx in [-2.0, 2] {
            let hit = window.contentView?.superview?.hitTest(NSPoint(x: frame.midX + dx, y: frame.midY))
            #expect(hit === handle, "dx \(dx): \(String(describing: hit))")
        }
        #expect(handle.isAccessibilityElement() && handle.accessibilityRole() == .splitter)
        #expect(handle.accessibilityLabel() == L10n.inspectorHandle.text)
        #expect(handle.accessibilityValue() as? Double == 270)
        #expect(handle.accessibilityPerformIncrement())
        #expect(model.inspectorWidth.points == 290, "increment")
        #expect(defaults.object(forKey: InspectorWidth.defaultsKey) as? Double == 290, "a step saves")
        model.inspectorWidth = InspectorWidth(400)
        #expect(handle.accessibilityPerformIncrement() && model.inspectorWidth.points == 400, "clamp")
        #expect(handle.accessibilityPerformDecrement() && model.inspectorWidth.points == 380, "decrement")
        await model.close()
    }

    // MARK: C13

    /// C13: at fit zoom, after a first and a second drag, the lanes draw the whole new width, and
    /// the ruler clips.
    @Test func theLanesDrawTheNewWidthAfterADrag() async throws {
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let (model, _, window, view) = try await open(try await package())
        window.setContentSize(NSSize(width: 1180, height: 600))
        await until("the window takes 1180 pt") { window.contentLayoutRect.width == 1180 }
        for (step, dx) in [("wider", -130.0), ("narrower", 160)] {
            let width = view.shown.width
            try drag(window, by: dx)
            await until("\(step): the lanes take the new width") {
                window.contentView?.layoutSubtreeIfNeeded()
                drawNow(window)
                return view.shown.width != width
                    && view.lanes.drawnRect.contains(view.shown.intersection(view.lanes.bounds))
            }
        }
        #expect(window.contentView.flatMap(scrollView)?.ruler.clipsToBounds == true, "the ruler clips")
        await model.close()
    }

    // MARK: C16 fallback

    /// C16, fallback 1 of 0023: during a drag the pane and the lanes keep their width, a guide line
    /// over the window shows the target edge, and no SwiftUI body runs. The mouse-up sets the width
    /// and removes the line. Control: a live width runs one content body and one inspector body for
    /// each drag event (release bench 13:36).
    @Test func aDragMovesTheGuideAndTheUpSetsTheWidth() async throws {
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let (model, _, window, _) = try await open(try await package())
        window.setContentSize(NSSize(width: 1180, height: 600))
        await until("the lanes give the pane its width") {
            window.contentLayoutRect.width == 1180 && layout(window) == 910
        }
        let view = try handle(window)
        let x = Double(view.convert(view.bounds, to: nil).midX)
        view.mouseDown(with: try event(.leftMouseDown, x, window))
        await runLoopPass()
        let (bodies, inspectorBodies) = (model.bodyRuns, model.inspectorRuns)
        for dx in [-20.0, -60, -100, 40] {
            view.mouseDragged(with: try event(.leftMouseDragged, x + dx, window))
            await runLoopPass()
            #expect(model.inspectorWidth == .standard && layout(window) == 910, "dx \(dx): the pane keeps 270 pt")
            let guide = model.inspectorGuide
            #expect(guide.superlayer != nil && guide.superlayer === window.contentView?.layer, "dx \(dx): no guide")
            let target = 1180 - min(400, max(240, 270 - dx))
            #expect(abs(Double(guide.frame.minX) - target) <= 0.5, "dx \(dx): guide at \(guide.frame)")
        }
        #expect(model.bodyRuns == bodies, "a drag ran \(model.bodyRuns - bodies) content bodies")
        #expect(
            model.inspectorRuns == inspectorBodies,
            "a drag ran \(model.inspectorRuns - inspectorBodies) inspector bodies")
        view.mouseUp(with: try event(.leftMouseUp, x + 40, window))
        #expect(model.inspectorWidth.points == 240, "the up sets the clamped width")
        #expect(model.inspectorGuide.superlayer == nil, "the up removes the guide")
        await until("the lanes take the new width") { layout(window) == 940 }
        await model.close()
    }
}
