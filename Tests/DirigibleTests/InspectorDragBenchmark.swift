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
/// pass of the main run loop (the SwiftUI update of the content), the layout, and the draw of the
/// lanes, timed to the end of `drawNow`. A real session window has 1440 x 600 pt of content at
/// scale 2 (2880 x 1200 px), with the inspector at 270 pt.
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
            try studio.edit { s throws(SessionError) in s = session }
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

            let (inspectorRuns, contentRuns) = (model.inspectorRuns, model.bodyRuns)
            var times: [Duration] = []
            for (event, width) in Self.path.enumerated() {
                let before = view.frame.width
                try await Task.sleep(for: .microseconds(16_700))
                let start = ContinuousClock.now
                handle.mouseDragged(with: try Self.event(.leftMouseDragged, x + 270 - width, window))
                await Self.pass()
                window.contentView?.layoutSubtreeIfNeeded()
                drawNow(window)
                let time = ContinuousClock.now - start
                // The first 10 events are not timed (the draws after the window shows).
                if event >= 10 { times.append(time) }
                try #require(model.inspectorWidth.points == width, "\(zoom): width \(model.inspectorWidth.points)")
                try #require(view.frame.width != before, "\(zoom): the lanes kept \(before) pt at \(width)")
            }
            handle.mouseUp(with: try Self.event(.leftMouseUp, x, window))
            let inspector = model.inspectorRuns - inspectorRuns
            let content = model.bodyRuns - contentRuns

            let sorted = times.sorted()
            let p95 = sorted[Int(Double(sorted.count) * 0.95)]
            print(
                "InspectorDragBenchmark \(zoom): drag p50 \(sorted[sorted.count / 2]), p95 \(p95),"
                    + " max \(sorted.last!), \(sorted.count) events, \(inspector) inspector bodies and"
                    + " \(content) content bodies for \(Self.path.count) drag events")
            expectWithinBudget(p95, MouseEventBenchmark.budget, "inspector drag p95 \(zoom): \(p95)")
            #expect(inspector <= Self.path.count, "\(zoom): \(inspector) inspector bodies")
            window.close()
            await model.close()
        }
    }

    static func handle(_ view: NSView) -> InspectorHandleView? {
        view as? InspectorHandleView ?? view.subviews.lazy.compactMap(handle).first
    }

    static func event(_ type: NSEvent.EventType, _ x: Double, _ window: NSWindow) throws -> NSEvent {
        try #require(
            NSEvent.mouseEvent(
                with: type, location: NSPoint(x: x, y: window.contentLayoutRect.midY), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: 1))
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
