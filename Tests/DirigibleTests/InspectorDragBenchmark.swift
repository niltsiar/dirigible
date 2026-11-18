import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Run ui-polish-chrome criterion C16: one inspector divider event on the 2 h fixture fits one
/// 60 Hz frame, p95 16 ms or less with -O (`make bench FILTER=InspectorDragBenchmark`); the debug
/// proxy budget is 100 ms, as `MouseEventBenchmark`. An event is the handle `mouseDragged`, one
/// pass of the main run loop, the layout, and the draw, timed to the end of `drawNow`. A real
/// session window has 1440 x 600 pt of content at scale 2 (2880 x 1200 px), with the inspector at
/// 270 pt. A live width missed the budget (p95 26 ms fit, 24.8 ms at 60 pt boxes, 13:36), so a
/// drag moves only the guide line (fallback 1 of 0023): each drag event runs no SwiftUI body and
/// draws no lanes. The mouse-up lays out the lanes at the new width once; it may take two frames,
/// as the one-off events of `HeaderDragBenchmark`. In a debug build the time budgets only print,
/// and every structure check (the width, the guide, the draws, the bodies) still fails the test.
@MainActor struct InspectorDragBenchmark {
    /// Widen 270 to 400, narrow 400 to 240, widen 240 to 270, 2 to 4 pt a frame: 81 events.
    static let path: [Double] =
        Array(stride(from: 272.0, through: 400, by: 4)) + Array(stride(from: 396.0, through: 240, by: -4))
        + Array(stride(from: 242.0, through: 270, by: 4))

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aDividerDragEventFitsOneFrameAtTwoHours() async throws {
        let folder = try TemporaryFolder()
        let suite = "InspectorDragBenchmark.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let app = AppDelegate(recordings: nil, defaults: defaults)
        app.snaps = false
        NSWindow.allowsAutomaticWindowTabbing = false
        let (session, peaks) = try MouseEventBenchmark.fixture()
        for (n, (zoom, framesPerPoint)) in MouseEventBenchmark.zooms.enumerated() {
            let place = folder.url.appending(path: "\(n)")
            try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
            let package = try await timelinePackage(in: place, tracks: 1, seconds: 1)
            let (model, studio, window, view) = try await openLanes(app, package)
            // The 2 h session and its peaks, and a save that does not write (`lanesOnScreen`).
            let url = studio.url
            studio.environment.saveSession = { _, _ in url }
            try studio.edit(ripple: false) { s throws(SessionError) in s = session }
            studio.peakLoad.states = peaks
            if !model.showsInspector { model.toggleInspector() }
            window.setContentSize(NSSize(width: 1440, height: 600))
            await until("the window takes 1440 pt") { window.contentLayoutRect.width == 1440 }
            model.timeline.scale = TimelineScale(framesPerPoint: framesPerPoint)
            await runLoopPass()
            drawNow(window)
            try #require(window.backingScaleFactor == 2, "this display has scale \(window.backingScaleFactor)")
            try #require(model.inspectorWidth == .standard, "\(model.inspectorWidth)")
            let handle = try #require(window.contentView.flatMap(Self.handle), "no inspector handle")
            let x = Double(handle.convert(handle.bounds, to: nil).midX)
            handle.mouseDown(with: try Self.event(.leftMouseDown, x, window))

            await Self.pass()
            let (inspectorRuns, contentRuns) = (model.inspectorRuns, model.bodyRuns)
            let lanesWidth = view.frame.width
            var times: [Duration] = []
            for (event, width) in Self.path.enumerated() {
                let draws = view.lanes.draws
                let time = try await Self.timed(window) {
                    handle.mouseDragged(with: try Self.event(.leftMouseDragged, x + 270 - width, window))
                }
                // The first 10 events are not timed (the draws after the window shows).
                if event >= 10 { times.append(time) }
                try #require(model.inspectorResize.preview?.points == width, "\(zoom): target \(width)")
                try #require(
                    Double(model.inspectorResize.guide.frame.minX) == 1440 - width,
                    "\(zoom): guide \(model.inspectorResize.guide.frame)")
                try #require(model.inspectorWidth == .standard && view.frame.width == lanesWidth, "\(zoom): live width")
                try #require(view.lanes.draws == draws, "\(zoom): a drag event drew the lanes")
            }
            let inspector = model.inspectorRuns - inspectorRuns
            let content = model.bodyRuns - contentRuns
            // The one-off event: the up at 400 pt lays out and draws the lanes at the new width.
            _ = try await Self.timed(window) {
                handle.mouseDragged(with: try Self.event(.leftMouseDragged, x - 130, window))
            }
            let draws = view.lanes.draws
            let up = try await Self.timed(window) {
                handle.mouseUp(with: try Self.event(.leftMouseUp, x - 130, window))
            }
            try #require(model.inspectorWidth.points == 400 && view.frame.width == lanesWidth - 130, "\(zoom): up")
            try #require(view.lanes.draws > draws, "\(zoom): the up drew no lanes")

            let sorted = times.sorted()
            let p95 = sorted[Int(Double(sorted.count) * 0.95)]
            print(
                "InspectorDragBenchmark \(zoom): drag p50 \(sorted[sorted.count / 2]), p95 \(p95),"
                    + " max \(sorted.last!), \(sorted.count) events, \(inspector) inspector bodies and"
                    + " \(content) content bodies for \(Self.path.count) drag events; up at 400 pt \(up)")
            expectWithinBudget(p95, MouseEventBenchmark.budget, "inspector drag p95 \(zoom): \(p95)")
            expectWithinBudget(up, MouseEventBenchmark.budget * 2, "inspector up \(zoom): \(up)")
            #expect(inspector == 0 && content == 0, "\(zoom): \(inspector) inspector and \(content) content bodies")
            // The up saved 400 pt: the window of the next zoom starts at 270 pt.
            defaults.removeObject(forKey: InspectorWidth.defaultsKey)
            window.close()
            await model.close()
        }
    }

    static func handle(_ view: NSView) -> PaneHandleView? {
        if let handle = view as? PaneHandleView, handle.edge == .trailing { return handle }
        return view.subviews.lazy.compactMap(handle).first
    }

    static func event(_ type: NSEvent.EventType, _ x: Double, _ window: NSWindow) throws -> NSEvent {
        try #require(
            NSEvent.mouseEvent(
                with: type, location: NSPoint(x: x, y: window.contentLayoutRect.midY), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: 1))
    }

    /// The time of `action`, one run loop pass, the layout, and the draw, after a sleep to the next
    /// 60 Hz frame.
    static func timed(_ window: NSWindow, _ action: () throws -> Void) async throws -> Duration {
        try await Task.sleep(for: .microseconds(16_700))
        let start = ContinuousClock.now
        try action()
        await pass()
        window.contentView?.layoutSubtreeIfNeeded()
        drawNow(window)
        return ContinuousClock.now - start
    }

    /// Returns after the end of one pass of the main run loop, with no poll: `runLoopPass` sleeps
    /// 10 ms between its checks, which the timed part must not have.
    static func pass() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let observer = CFRunLoopObserverCreateWithHandler(
                nil, CFRunLoopActivity.beforeWaiting.rawValue, false, .max
            ) { _, _ in done.resume() }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
    }
}
