import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Criteria B1, B2, and B4 of run 11b-1 on the 2 h fixture of `MouseEventBenchmark`, optimized
/// (`make bench FILTER=MouseEventGainBenchmark`): one gain drag event and one fade-handle drag
/// event fit one 60 Hz frame (p95 16 ms or less), their mouse-up and the double-click reset fit
/// two frames (32 ms), and the full draw with a gain line on each box fits one frame. At fit zoom a
/// fixture clip is 0.72 pt wide (no line, no handle), so a clip of 12,000,000 frames (50 pt) on t2
/// takes the press; at the zoom of 60 pt boxes, a fixture clip at x 300 on t2 does.
@MainActor struct MouseEventGainBenchmark {
    /// Two frames: the budget of a one-off event (the `HeaderDragBenchmark` rule).
    static let oneOff = MouseEventBenchmark.budget * 2

    /// The fixture with "big" on t2 (no butt join with no fade: it has the fades of the fixture).
    static func fixture() throws -> (Session, [FileID: PeakState]) {
        var (session, peaks) = try MouseEventBenchmark.fixture()
        try session.place(
            Clip(id: "big", file: "f2", start: 100_000_000, offset: 100_000_000, length: 12_000_000), on: "t2")
        try session.setFades(["big": #require(Fades(fadeIn: 24_000, fadeOut: 24_000))])
        return (session, peaks)
    }

    /// Runs `body` with the lanes on screen at each zoom, with the box that takes the press.
    static func eachZoom(
        _ session: Session, _ peaks: [FileID: PeakState],
        _ body: @MainActor (String, NSWindow, TimelineScrollView, NSRect) async throws -> Void
    ) async throws {
        let folder = try TemporaryFolder()
        let app = AppDelegate(recordings: nil)
        for (n, (zoom, framesPerPoint)) in MouseEventBenchmark.zooms.enumerated() {
            let package = folder.url.appending(path: "\(n)")
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            let (window, view, model) = try await MouseEventBenchmark.lanesOnScreen(
                session, peaks, framesPerPoint: framesPerPoint, app: app, folder: package)
            try #require(window.backingScaleFactor == 2, "this display has scale \(window.backingScaleFactor)")
            let box = try #require(
                n == 0 ? view.lanes.clipFrame("big") : NSRect(x: 300, y: 100, width: 60, height: 100))
            try #require(box.width >= LaneGeometry.controlsWidth && box.maxX < 1300, "\(zoom): \(box)")
            try await body(zoom, window, view, box)
            window.close()
            await model.close()
        }
    }

    static func report(_ name: String, _ zoom: String, _ sorted: [Duration], oneOff: [Duration]) {
        print(
            "MouseEventGainBenchmark \(name), \(zoom): p50 \(sorted[60]), p95 \(sorted[113]),"
                + " up \(oneOff[0]), double-click \(oneOff[1])")
        expectWithinBudget(sorted[113], MouseEventBenchmark.budget, "\(name) \(zoom): p95 \(sorted[113])")
        for time in oneOff { expectWithinBudget(time, Self.oneOff, "\(name) \(zoom): one-off \(time)") }
    }

    /// The time of `action` and the draw that it causes, after a sleep to the next 60 Hz frame.
    static func timed(_ window: NSWindow, _ action: () throws -> Void) async throws -> Duration {
        try await Task.sleep(for: .microseconds(16_700))
        let start = ContinuousClock.now
        try action()
        drawNow(window)
        return ContinuousClock.now - start
    }

    /// B1 and B2, the gain line: the press 3 pt under the box top (the band of a 0 dB clip, between
    /// the fades); each event takes the line to -6 or -12 dB (10 or 20 pt down), a new value. Then
    /// the mouse-up commit, and a double-click on the band at -6 dB that resets it to 0 dB.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aGainDragEventFitsOneFrameAtTwoHours() async throws {
        let (session, peaks) = try Self.fixture()
        try await Self.eachZoom(session, peaks) { zoom, window, view, box in
            let down = NSPoint(x: box.midX, y: box.minY + 3)
            view.lanes.mouseDown(with: try mouse(.leftMouseDown, down, in: view))
            let sorted = try await MouseEventBenchmark.pacedDrags(view, window, zoom) { event in
                try mouse(.leftMouseDragged, NSPoint(x: down.x, y: down.y + (event % 2 == 0 ? 10 : 20)), in: view)
            }
            let up = try await Self.timed(window) {
                view.lanes.mouseUp(with: try mouse(.leftMouseUp, NSPoint(x: down.x, y: down.y + 10), in: view))
            }
            let line = NSPoint(x: down.x, y: box.minY + 10)
            let reset = try await Self.timed(window) {
                view.lanes.mouseDown(with: try mouse(.leftMouseDown, line, in: view, clicks: 2))
                view.lanes.mouseUp(with: try mouse(.leftMouseUp, line, in: view, clicks: 2))
            }
            let clips = try #require(view.lanes.inputs?.session.tracks[1].clips)
            let index = try #require(clips.index(holding: Frames(Int(down.x * view.lanes.framesPerPoint))))
            try #require(clips[index].gain == .zero, "\(zoom): the double-click reset the gain")
            Self.report("gain", zoom, sorted, oneOff: [up, reset])
        }
    }

    /// B1 and B2, the fade-in handle: the press on the handle at the fade-in end; each event takes
    /// the fade end 3 to 12 pt right, a new value. Then the mouse-up commit, and a double-click on
    /// the handle at its new place that removes the fade-in.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aFadeHandleDragEventFitsOneFrameAtTwoHours() async throws {
        let (session, peaks) = try Self.fixture()
        try await Self.eachZoom(session, peaks) { zoom, window, view, box in
            let fadeEnd = box.minX + 24_000 / view.lanes.framesPerPoint
            let down = NSPoint(x: max(fadeEnd, box.minX + 4), y: box.minY + 4)
            view.lanes.mouseDown(with: try mouse(.leftMouseDown, down, in: view))
            let sorted = try await MouseEventBenchmark.pacedDrags(view, window, zoom) { event in
                try mouse(.leftMouseDragged, NSPoint(x: down.x + Double(3 + event % 10), y: down.y), in: view)
            }
            let moved = NSPoint(x: down.x + 3, y: down.y)
            let up = try await Self.timed(window) {
                view.lanes.mouseUp(with: try mouse(.leftMouseUp, moved, in: view))
            }
            let handle = NSPoint(x: fadeEnd + 3, y: down.y)
            let reset = try await Self.timed(window) {
                view.lanes.mouseDown(with: try mouse(.leftMouseDown, handle, in: view, clicks: 2))
                view.lanes.mouseUp(with: try mouse(.leftMouseUp, handle, in: view, clicks: 2))
            }
            Self.report("fade", zoom, sorted, oneOff: [up, reset])
        }
    }

    /// B4: the full draw of the lanes in view with -20 dB on every second clip (the line 33 pt under
    /// the lane top) and the labels with the gain, 120 times at each zoom.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func theLanesWithGainLinesDrawInOneFrame() async throws {
        var (session, peaks) = try Self.fixture()
        let quiet = try #require(Gain(dB: -20))
        for id in session.tracks.flatMap({ $0.clips.enumerated().filter { $0.offset % 2 == 1 }.map(\.element.id) }) {
            try session.setGain(quiet, clip: id)
        }
        try await Self.eachZoom(session, peaks) { zoom, window, view, _ in
            for _ in 0..<10 {
                view.lanes.setNeedsDisplay(view.shown)
                drawNow(window)
            }
            var times: [Duration] = []
            for _ in 0..<120 {
                let draws = view.lanes.draws
                view.lanes.setNeedsDisplay(view.shown)
                let start = ContinuousClock.now
                drawNow(window)
                times.append(ContinuousClock.now - start)
                try #require(view.lanes.draws == draws + 1, "one draw per event")
            }
            let sorted = times.sorted()
            print("MouseEventGainBenchmark draw, \(zoom): p50 \(sorted[60]), p95 \(sorted[113])")
            expectWithinBudget(sorted[113], MouseEventBenchmark.budget, "draw \(zoom): p95 \(sorted[113])")
        }
    }
}
