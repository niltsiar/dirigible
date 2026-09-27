import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import SwiftUI
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Run 1b criterion H11: one header handle event on the 2 h fixture fits one 60 Hz frame, p95 16 ms
/// or less with -O (`make bench FILTER=HeaderDragBenchmark`); the debug proxy budget is 100 ms, as
/// `MouseEventBenchmark`. An event is the drag state, `ruleThickness`, `tile()`, the layout of the
/// header rows, and the lanes render, timed to the end of `drawNow`. The window has 1440 pt of lanes
/// at the 340 pt default, 600 pt high, at scale 2. The case with no rows gives the lanes part.
@MainActor struct HeaderDragBenchmark {
    /// Widen 340 to 480, narrow 480 to 180, widen 180 to 340, 4 pt a frame: 150 events.
    static let path: [Double] =
        Array(stride(from: 344.0, through: 480, by: 4)) + Array(stride(from: 476.0, through: 180, by: -4))
        + Array(stride(from: 184.0, through: 340, by: 4))

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aHeaderDragEventFitsOneFrameAtTwoHours() async throws {
        try await measure(rows: true)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aHeaderDragEventWithNoRowsFitsOneFrameAtTwoHours() async throws {
        try await measure(rows: false)
    }

    func measure(rows: Bool) async throws {
        let folder = try TemporaryFolder()
        let app = AppDelegate(recordings: nil)
        let (session, peaks) = try MouseEventBenchmark.fixture()
        let name = rows ? "rows" : "no rows"
        for (n, (zoom, framesPerPoint)) in MouseEventBenchmark.zooms.enumerated() {
            let package = folder.url.appending(path: "\(n)")
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            let (window, view, model) = try await MouseEventBenchmark.lanesOnScreen(
                session, peaks, framesPerPoint: framesPerPoint, app: app, folder: package)
            let studio = try #require(model.studio)
            if rows {
                view.headers.host.rootView = AnyView(TrackHeaders(model: model, studio: studio, laneHeight: 100))
            }
            drawNow(window)
            try #require(window.backingScaleFactor == 2, "this display has scale \(window.backingScaleFactor)")
            try #require(view.shown.width == 1440 && view.shown.height >= 600, "\(view.shown)")
            let bench = Paced(view: view, window: window, zoom: "\(name), \(zoom)")

            try bench.send(.leftMouseDown, 337)
            let layouts = view.headers.layouts
            var times: [Duration] = []
            for (event, width) in Self.path.enumerated() {
                let time = try await bench.timed(.leftMouseDragged, width - 3)
                if event >= 10 { times.append(time) }
                try #require(Double(view.headers.ruleThickness) == width, "\(bench.zoom): live width \(width)")
                try #require(Double(view.headers.host.frame.width) == width, "\(bench.zoom): host width \(width)")
                if n == 0 {
                    try #require(
                        view.lanes.frame.width >= view.shown.maxX, "\(bench.zoom): the lanes cover the view at \(width)"
                    )
                }
            }
            let layoutCount = view.headers.layouts - layouts
            // Esc in a second drag, the mouse-up of a third, a double-click, and an AX step.
            try bench.send(.leftMouseDown, 337)
            _ = try await bench.timed(.leftMouseDragged, 397)
            times.append(try await bench.timed { _ = view.headers.cancelDrag() })
            try #require(view.headers.width == .standard, "\(bench.zoom): Esc gives the start width")
            try bench.send(.leftMouseDown, 337)
            _ = try await bench.timed(.leftMouseDragged, 397)
            // The up only saves (nil in the harness): no render.
            times.append(try await bench.timed(.leftMouseUp, 397, renders: false))
            times.append(try await bench.timed(.leftMouseDown, 397, clicks: 2))
            try #require(view.headers.width == .standard, "\(bench.zoom): double-click")
            times.append(try await bench.timed { _ = view.headers.handle.accessibilityPerformIncrement() })
            try #require(view.headers.width == HeaderWidth(360), "\(bench.zoom): AX step")

            let sorted = times.sorted()
            let p95 = sorted[Int(Double(sorted.count) * 0.95)]
            print(
                "HeaderDragBenchmark \(bench.zoom): p50 \(sorted[sorted.count / 2]), p95 \(p95), max \(sorted.last!),"
                    + " \(sorted.count) events, \(layoutCount) header layouts for \(Self.path.count) drag events")
            #expect(p95 <= MouseEventBenchmark.budget, "header drag p95 \(bench.zoom): \(p95)")
            window.close()
            await model.close()
        }
    }
}

/// Handle events at one per 60 Hz frame. Each timed event that changes the width renders the lanes
/// once.
@MainActor struct Paced {
    let view: TimelineScrollView
    let window: NSWindow
    let zoom: String

    func send(_ type: NSEvent.EventType, _ x: Double, clicks: Int = 1) throws {
        let location = view.headers.convert(NSPoint(x: x, y: view.headers.bounds.midY), to: nil)
        let event = try #require(
            NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: clicks, pressure: 1))
        switch type {
        case .leftMouseDown: view.headers.handle.mouseDown(with: event)
        case .leftMouseDragged: view.headers.handle.mouseDragged(with: event)
        default: view.headers.handle.mouseUp(with: event)
        }
    }

    func timed(_ type: NSEvent.EventType, _ x: Double, clicks: Int = 1, renders: Bool = true) async throws
        -> Duration
    {
        try await timed(renders: renders) { try send(type, x, clicks: clicks) }
    }

    /// The time of `action` and the draw that it causes, after a sleep to the next 60 Hz frame.
    func timed(renders: Bool = true, _ action: () throws -> Void) async throws -> Duration {
        let draws = view.lanes.draws
        try await Task.sleep(for: .microseconds(16_700))
        let start = ContinuousClock.now
        try action()
        drawNow(window)
        let time = ContinuousClock.now - start
        try #require(
            view.lanes.draws == draws + (renders ? 1 : 0),
            "\(zoom): the event rendered \(view.lanes.draws - draws) times")
        return time
    }
}
