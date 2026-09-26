import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp

/// Timeline-scroll criterion 9: one follow or scroll step fits one 60 Hz frame, p95 16 ms or less
/// over 120 steps with -O (`make bench FILTER=FollowScrollBenchmark`), 100 ms in debug. The 2 h
/// fixture of `MouseEventBenchmark` in 2880 x 1200 px, one step per 60 Hz frame. A step is the
/// scroll and the draw that it causes: a forward page turn, a reverse page turn, or a user scroll
/// of 20 pt (a trackpad).
@MainActor struct FollowScrollBenchmark {
    /// The zoom of 60 pt boxes, and a zoom where the session is 10 pages.
    static let zooms = [
        ("60 pt boxes", Double(MouseEventBenchmark.frames / 2000) / 60),
        ("10 pages", Double(MouseEventBenchmark.frames) * 1.02 / 14_400),
    ]
    static let forward = Playback.playing(Shuttle(direction: .forward, rate: .one))
    static let reverse = Playback.playing(Shuttle(direction: .reverse, rate: .one))

    /// The lanes of the 2 h fixture at each zoom, with no display link: its ticks read the stopped
    /// Studio, and a playhead that is not the last one is a seek back to frame 0.
    static func eachZoom(_ run: @MainActor (String, NSWindow, TimelineScrollView) async throws -> Void) async throws {
        let folder = try TemporaryFolder()
        let app = AppDelegate(recordings: nil)
        let (session, peaks) = try MouseEventBenchmark.fixture()
        for (n, (zoom, framesPerPoint)) in zooms.enumerated() {
            let package = folder.url.appending(path: "\(n)")
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            let (window, view, model) = try await MouseEventBenchmark.lanesOnScreen(
                session, peaks, framesPerPoint: framesPerPoint, app: app, folder: package)
            view.viewWillMove(toWindow: nil)
            try #require(window.backingScaleFactor == 2, "this display has scale \(window.backingScaleFactor)")
            try #require(view.shown.width == 1440 && view.shown.height >= 600, "\(view.shown)")
            try await run(zoom, window, view)
            window.close()
            await model.close()
        }
    }

    /// Runs 130 steps, one per 60 Hz frame, and gives the sorted times of the last 120. `prepare`
    /// runs before the timer (a jump back when the lanes end), and `step` is the timed step. Each
    /// step must scroll and draw the lanes once, at most `width` points: the new columns, not all
    /// lanes in view (a mark of the lanes out of view next to the view drew them all on screen).
    static func paced(
        _ view: TimelineScrollView, _ window: NSWindow, _ name: String, width: Double, prepare: () -> Void = {},
        step: () -> Void
    ) async throws -> [Duration] {
        var times: [Duration] = []
        for n in 1...130 {
            prepare()
            drawNow(window)
            let (origin, draws) = (view.origin, view.lanes.draws)
            try await Task.sleep(for: .microseconds(16_700))
            let start = ContinuousClock.now
            step()
            drawNow(window)
            // The first 10 steps are not timed (the draw after the window shows).
            if n > 10 { times.append(ContinuousClock.now - start) }
            try #require(view.origin != origin, "\(name): step \(n) did not scroll")
            try #require(view.lanes.draws == draws + 1, "\(name): step \(n) drew \(view.lanes.draws - draws) times")
            try #require(view.lanes.drawnRect.width <= width, "\(name): step \(n) drew \(view.lanes.drawnRect)")
        }
        return times.sorted()
    }

    /// A jump to `frame` before a timed step, with a full redraw, so the next pages are not drawn yet.
    static func jump(_ view: TimelineScrollView, to frame: Double) {
        view.scroll(toFrame: frame)
        view.lanes.needsDisplay = true
    }

    static func report(_ name: String, _ zoom: String, _ sorted: [Duration]) {
        print("FollowScrollBenchmark \(name), \(zoom): p50 \(sorted[60]), p95 \(sorted[113])")
        #expect(sorted[113] <= MouseEventBenchmark.budget, "\(name), \(zoom): p95 \(sorted[113])")
    }

    /// A forward page turn: the playhead at 95% of the page turns it (decision 0017).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aForwardPageTurnFitsOneFrameAtTwoHours() async throws {
        try await Self.eachZoom { zoom, window, view in
            // The first tick only takes the state.
            view.tick(playhead: 0, playback: Self.forward)
            let end = Double(MouseEventBenchmark.frames)
            let sorted = try await Self.paced(view, window, "forward", width: 0.9 * view.shown.width) {
                if view.origin + 2 * view.visibleFrames > end { Self.jump(view, to: 0) }
            } step: {
                view.tick(playhead: view.origin + 0.95 * view.visibleFrames, playback: Self.forward)
            }
            Self.report("forward", zoom, sorted)
        }
    }

    /// A reverse page turn: the playhead under 6% of the page turns it back.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aReversePageTurnFitsOneFrameAtTwoHours() async throws {
        try await Self.eachZoom { zoom, window, view in
            view.tick(playhead: 0, playback: Self.reverse)
            let last = Double(MouseEventBenchmark.frames) - 1.5 * view.visibleFrames
            let sorted = try await Self.paced(view, window, "reverse", width: 0.9 * view.shown.width) {
                if view.origin < view.visibleFrames { Self.jump(view, to: last) }
            } step: {
                view.tick(playhead: view.origin + 0.04 * view.visibleFrames, playback: Self.reverse)
            }
            Self.report("reverse", zoom, sorted)
        }
    }

    /// A user scroll of 20 pt per frame, as a trackpad gives it.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aUserScrollStepFitsOneFrameAtTwoHours() async throws {
        try await Self.eachZoom { zoom, window, view in
            let sorted = try await Self.paced(
                view, window, "scroll", width: 22,
                step: { view.scroll(toFrame: view.origin + 20 * view.framesPerPoint) })
            Self.report("scroll", zoom, sorted)
        }
    }
}
