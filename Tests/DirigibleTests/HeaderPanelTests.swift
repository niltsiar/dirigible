import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Run 1b criteria H3 and H5: the handle at the trailing edge of the track headers sets the header
/// width live, Esc restores the start width, a double-click sets 340 pt, and VoiceOver reads a
/// splitter with the width. The events go to the hit view of the frame view (learning c555674).
@Suite(.serialized) @MainActor struct HeaderPanelTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws {
        NSWindow.allowsAutomaticWindowTabbing = false
        folder = try TemporaryFolder()
    }

    /// A standalone window of 1440 pt of lanes plus the header `width`, with the lanes of a
    /// 2-track package of 60 s at 512 frames per point.
    func standalone(width: HeaderWidth) async throws -> (NSWindow, TimelineScrollView, SessionWindow) {
        let (model, studio) = try await timelineModel(
            try await timelinePackage(in: folder.url, tracks: 2, seconds: 60), app: app)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440 + width.points + scrollerWidth, height: 400 + scrollerWidth),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = TimelineScrollView(model: model, studio: studio, headerWidth: width)
        view.frame = try #require(window.contentView).bounds
        window.contentView?.addSubview(view)
        view.update(laneInputs(model, studio))
        // The first update fits the session; the tests use 512 frames per point (5,625 pt of lanes).
        view.update(laneInputs(model, studio))
        drawNow(window)
        return (window, view, model)
    }

    /// Sends a mouse event at the ruler x `x` of the header handle, at the middle height. A mouse-down goes to the hit
    /// view of the frame view, which must be the handle; a drag or an up goes to the handle.
    func handle(_ type: NSEvent.EventType, _ x: Double, _ view: TimelineScrollView, clicks: Int = 1) throws {
        let window = try #require(view.window)
        // The time ruler covers the top of the header ruler, so the event is at the middle height.
        let location = view.headers.convert(NSPoint(x: x, y: view.headers.bounds.midY), to: nil)
        let event = try #require(
            NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: clicks, pressure: 1))
        switch type {
        case .leftMouseDown:
            // A real event comes after the display pass, which lays out the handle.
            drawNow(window)
            let hit = window.contentView?.superview?.hitTest(location)
            try #require(hit === view.headers.handle, "the handle takes the mouse-down at x \(x), not \(hit as Any)")
            view.headers.handle.mouseDown(with: event)
        case .leftMouseDragged: view.headers.handle.mouseDragged(with: event)
        default: view.headers.handle.mouseUp(with: event)
        }
    }

    /// Plan gate 1 item 1: a header drag does not hold the lanes width, so at each event of a
    /// narrowing drag at fit zoom the lanes cover the view (no blank part at the right).
    @Test func aNarrowingDragAtFitZoomCoversTheView() async throws {
        let (window, view, model) = try await standalone(width: HeaderWidth(480))
        let studio = try #require(model.studio)
        // Fit zoom (1440 pt of lanes), and the fit of the bench: the session end + 2% at 2,000
        // frames per point is 1468.8 pt, not whole points.
        for zoom in ["fit", "2000"] {
            if zoom == "fit" {
                view.zoomToSession()
            } else {
                var inputs = laneInputs(model, studio)
                inputs.scale = TimelineScale(framesPerPoint: 2000)
                view.update(inputs)
            }
            drawNow(window)
            try #require(Double(view.headers.ruleThickness) == 480 && view.shown.minX == 0, "\(zoom): \(view.shown)")
            try handle(.leftMouseDown, 477, view)
            // Narrow to 180 pt, then widen back: the lanes grow, then shrink to the session.
            let path =
                Array(stride(from: 460.0, through: 180, by: -20)) + Array(stride(from: 200.0, through: 480, by: 20))
            for width in path {
                try handle(.leftMouseDragged, width - 3, view)
                drawNow(window)
                // The #expect macro compares a CGFloat with a Double as unequal: compare two Doubles.
                #expect(Double(view.headers.ruleThickness) == width, "live width \(width)")
                #expect(
                    view.lanes.frame.width >= view.shown.maxX,
                    "the lanes cover the view, \(zoom), \(width): \(view.lanes.frame.width) < \(view.shown.maxX)")
            }
            try handle(.leftMouseUp, 477, view)
        }
        window.close()
        await model.close()
    }

    /// Criterion H3 (the scroller part comes in slice 4): the width changes at each event, and the
    /// lanes in view start at the same document x during the drag. A narrowing drag makes AppKit
    /// clamp the clip bounds to the new inset first, so a second shift by the inset change moved
    /// the lanes 4 pt at each event (the bench of slice 1).
    @Test func aHandleDragSetsTheWidthLive() async throws {
        let (window, view, model) = try await standalone(width: .standard)
        let autohides = view.autohidesScrollers
        // At 0 pt the clip bounds are at the leading inset, where AppKit clamps them.
        for left in [700.0, 0] {
            view.scroll(toFrame: left * view.framesPerPoint)
            drawNow(window)
            try #require(Double(view.shown.minX) == left)
            try handle(.leftMouseDown, Double(view.headers.ruleThickness) - 3, view)
            let capacity = try #require(view.lanes.surfaces.shown?.capacity)
            for width in [400.0, 480, 440, 300, 180, 260, 340] {
                try handle(.leftMouseDragged, width - 3, view)
                drawNow(window)
                // The 4 slots stay: a new capacity would drop them and render all lanes in view.
                #expect(view.lanes.surfaces.shown?.capacity == capacity, "a header drag keeps the capacity at \(width)")
                #expect(Double(view.headers.ruleThickness) == width, "live width \(width)")
                #expect(
                    Double(view.shown.minX) == left,
                    "the lanes keep their left edge at \(left), \(width): \(view.shown.minX)")
            }
            try handle(.leftMouseUp, 337, view)
        }
        // H13: the lanes follow the system setting "Show scroll bars" after a header drag.
        #expect(view.scrollerStyle == NSScroller.preferredScrollerStyle, "scroller style")
        #expect(view.autohidesScrollers == autohides, "scroller style: autohides")
        window.close()
        await model.close()
    }

    /// Criterion H3: the hit area of the handle is the 6 pt inside the trailing edge of the
    /// headers, above the rows, over the full height below the time ruler.
    @Test func theHandleHitAreaIsSixPointsInsideTheHeaders() async throws {
        let (window, view, model) = try await standalone(width: .standard)
        for width in [340.0, 180, 480] {
            view.headers.width = HeaderWidth(width)
            drawNow(window)
            func hit(_ x: Double, _ y: Double) -> NSView? {
                window.contentView?.superview?.hitTest(view.headers.convert(NSPoint(x: x, y: y), to: nil))
            }
            // The middle of lane 1, and the bottom of the headers (below the lanes).
            let lane = view.headers.convert(NSPoint(x: 0, y: 50), from: view.lanes).y
            for y in [lane, view.headers.bounds.maxY - 2] {
                #expect(hit(width - 0.5, y) === view.headers.handle, "handle at \(width) - 0.5, y \(y)")
                #expect(hit(width - 6, y) === view.headers.handle, "handle at \(width) - 6, y \(y)")
                #expect(hit(width - 7, y) !== view.headers.handle, "not the handle at \(width) - 7, y \(y)")
            }
            #expect(hit(width + 1, lane) === view.lanes, "lanes at \(width) + 1")
        }
        window.close()
        await model.close()
    }

    /// Decision 0023, fallback 2 (run 1b slice 5): the rows keep their width during a drag, the
    /// ruler clips them, and they take the new width at the mouse-up; Esc gives them the start width.
    /// The handle follows the ruler width during the drag.
    @Test func theRowsTakeTheWidthAtTheMouseUp() async throws {
        let (window, view, model) = try await standalone(width: .standard)
        try handle(.leftMouseDown, 337, view)
        try handle(.leftMouseDragged, 417, view)
        drawNow(window)
        #expect(Double(view.headers.ruleThickness) == 420, "live width")
        #expect(view.headers.host.frame.width == 340, "the rows keep the start width during the drag")
        try handle(.leftMouseDragged, 397, view)
        drawNow(window)
        let hit = window.contentView?.superview?.hitTest(
            view.headers.convert(NSPoint(x: 399.5, y: view.headers.bounds.midY), to: nil))
        #expect(hit === view.headers.handle, "handle at 399.5 during the drag")
        try handle(.leftMouseUp, 397, view)
        drawNow(window)
        #expect(view.headers.host.frame.width == 400, "the rows take the width at the up")
        try handle(.leftMouseDown, 397, view)
        try handle(.leftMouseDragged, 297, view)
        drawNow(window)
        // A standalone window has no Esc route (UndoRoutingWindow): the call of its Esc.
        #expect(view.headers.cancelDrag())
        drawNow(window)
        #expect(view.headers.host.frame.width == 400, "the rows take the width at Esc")
        _ = view.headers.handle.accessibilityPerformIncrement()
        drawNow(window)
        #expect(view.headers.host.frame.width == 420, "the rows take the width at an AX step")
        window.close()
        await model.close()
    }

    /// Criterion H3: a SwiftUI update during a header drag (Add Track) keeps the drag and the width.
    @Test func anUpdateDuringAHeaderDragKeepsTheDrag() async throws {
        let (model, studio, _, view) = try await openLanes(
            app, try await timelinePackage(in: folder.url, tracks: 2, seconds: 20))
        try handle(.leftMouseDown, 337, view)
        try handle(.leftMouseDragged, 397, view)
        let updates = view.updates
        model.run(.addTrack)
        await until("the lanes get the new track") { studio.session.tracks.count == 3 && view.updates > updates }
        #expect(view.headers.width == HeaderWidth(400), "the update keeps the width")
        try handle(.leftMouseDragged, 417, view)
        #expect(view.headers.width == HeaderWidth(420), "the drag goes on after the update")
        try #require(view.window).sendEvent(try cgKey(53))
        #expect(view.headers.width == .standard, "the drag goes on: Esc gives the start width")
        await model.close()
    }

    /// Criterion H3: with a typed name in a focused field and a clip selection, a handle mouse-down
    /// commits the name and ends the text focus, and Esc during the drag restores the start width
    /// and keeps the selection (Esc does not reach Deselect All).
    @Test func escDuringAHeaderDragRestoresTheWidthAndKeepsTheSelection() async throws {
        let (model, studio, window, view) = try await openLanes(
            app, try await timelinePackage(in: folder.url, tracks: 2, seconds: 20))
        let marks = Marks(inPoint: 0, outPoint: 48_000, tracks: ["t1"])
        model.timeline.marks = marks
        let editor = try await focusName(in: window)
        editor.selectAll(nil)
        editor.insertText("Guest", replacementRange: editor.selectedRange())
        await until("the typed name is a draft") { model.drafts["t1"] == "Guest" }
        try #require(studio.session.track("t1")?.name == "T1")

        try handle(.leftMouseDown, 337, view)
        #expect(studio.session.track("t1")?.name == "Guest", "the names commit at the handle")
        #expect(window.firstResponder !== editor, "the names commit at the handle: the focus ends")
        try handle(.leftMouseDragged, 377, view)
        try handle(.leftMouseDragged, 417, view)
        #expect(view.headers.ruleThickness == 420, "live width")

        window.sendEvent(try cgKey(53))

        #expect(view.headers.width == .standard, "Esc restores the start width")
        #expect(view.headers.ruleThickness == 340, "Esc restores the ruler width")
        #expect(model.timeline.marks == marks, "the selection stays")
        try handle(.leftMouseUp, 417, view)
        #expect(view.headers.width == .standard, "Esc restores: the up after Esc changes nothing")
        await model.close()
    }

    /// An AX step can change the row width, which can rebuild the name fields, so it commits the
    /// typed names and ends the text focus first, as the handle mouse-down does.
    @Test func anAXStepCommitsTheTypedNames() async throws {
        let (model, studio, window, view) = try await openLanes(
            app, try await timelinePackage(in: folder.url, tracks: 2, seconds: 20))
        let editor = try await focusName(in: window)
        editor.selectAll(nil)
        editor.insertText("Guest", replacementRange: editor.selectedRange())
        await until("the typed name is a draft") { model.drafts["t1"] == "Guest" }

        _ = view.headers.handle.accessibilityPerformIncrement()

        #expect(studio.session.track("t1")?.name == "Guest", "an AX step commits the names")
        #expect(window.firstResponder !== editor, "an AX step commits the names: the focus ends")
        await model.close()
    }

    /// Criterion H3: a double-click on the handle sets 340 pt.
    @Test func aDoubleClickSetsTheStandardWidth() async throws {
        let (window, view, model) = try await standalone(width: .standard)
        try handle(.leftMouseDown, 337, view)
        try handle(.leftMouseDragged, 417, view)
        try handle(.leftMouseUp, 417, view)
        try #require(view.headers.width == HeaderWidth(420), "live width")

        try handle(.leftMouseDown, 417, view, clicks: 2)
        try handle(.leftMouseUp, 417, view, clicks: 2)

        #expect(view.headers.width == .standard, "double-click")
        #expect(view.headers.ruleThickness == 340, "double-click")
        window.close()
        await model.close()
    }

    /// Criterion H5: the handle is a splitter with the width as its value; an increment adds 20 pt
    /// and a decrement takes 20 pt, both in 180...480.
    @Test func theHandleIsASplitterWithTheWidth() async throws {
        let (window, view, model) = try await standalone(width: .standard)
        let handle = view.headers.handle
        #expect(handle.isAccessibilityElement(), "splitter")
        #expect(handle.accessibilityRole() == .splitter, "splitter")
        #expect(handle.accessibilityLabel() == L10n.headerHandle.text, "label")
        #expect(handle.accessibilityValue() as? Double == 340, "splitter value")

        var saved: [Double] = []
        view.headers.save = { saved.append($0.points) }
        #expect(handle.accessibilityPerformIncrement(), "increment")
        #expect(saved == [360], "increment saves")
        #expect(view.headers.ruleThickness == 360, "increment")
        #expect(handle.accessibilityValue() as? Double == 360, "increment")
        #expect(handle.accessibilityPerformDecrement(), "decrement")
        #expect(view.headers.width == .standard, "decrement")
        view.headers.width = HeaderWidth(470)
        _ = handle.accessibilityPerformIncrement()
        #expect(view.headers.width == HeaderWidth(480), "increment clamps at 480")
        view.headers.width = HeaderWidth(190)
        _ = handle.accessibilityPerformDecrement()
        #expect(view.headers.width == HeaderWidth(180), "decrement clamps at 180")
        window.close()
        await model.close()
    }
}
