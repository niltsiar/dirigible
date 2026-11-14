import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import SwiftUI
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Timeline-navigation criterion N24: a one-off navigation key on the 2 h fixture takes two 60 Hz
/// frames or less, 32 ms with -O (`make bench FILTER=NavigationKeyBenchmark`), 400 ms in debug (a
/// proxy). An event is the command, the SwiftUI update of the pane, and the lane render, timed to
/// the end of `drawNow`, at the fit and at 60 pt boxes, 20 timed times each after 5 untimed ones;
/// each must render the lanes.
@MainActor struct NavigationKeyBenchmark {
    #if DEBUG
        static let budget = 400
    #else
        static let budget = 32
    #endif

    /// Zoom In (not timed), then Zoom Back (timed).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aZoomBackFitsTwoFrames() async throws {
        try await Self.measure("Zoom Back") { model, _ in
            model.run(.zoomIn)
            return { model.run(.zoomBack) }
        }
    }

    /// H to a selection in the middle, then H back: both timed.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func anHToggleFitsTwoFrames() async throws {
        try await Self.measure("H") { model, _ in
            model.timeline.marks = Marks(inPoint: 100_000_000, outPoint: 110_000_000, tracks: ["t1"])
            return { model.run(.zoomToSelection) }
        }
    }

    /// A page with Option-Page Down, then back with Option-Page Up: both timed. At the fit a page
    /// moves nothing, so the zooms are 60 pt boxes and 10 pages.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aPageKeyFitsTwoFrames() async throws {
        try await Self.measure("page", zooms: [MouseEventBenchmark.zooms[1], FollowScrollBenchmark.zooms[1]]) {
            model, n in
            if n == 0 { model.timelineView?.scroll(toFrame: 100_000_000) }
            return { model.run(n % 2 == 0 ? .pageNext : .pagePrevious) }
        }
    }

    /// Waveform Zoom In from 60 to 72 dB, then Waveform Zoom Out: both timed. Each step draws the lanes
    /// in view again. The menu choice and the wheel take the same path.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aWaveformZoomFitsTwoFrames() async throws {
        try await Self.measure("waveform zoom") { model, n in
            { model.run(n % 2 == 0 ? .waveformZoomIn : .waveformZoomOut) }
        }
    }

    /// Taller Tracks from 100 to 120 pt, then Shorter Tracks: both timed. Each step makes new
    /// surface slots (0022), a full render, and the header rows at the new height.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aHeightStepFitsTwoFrames() async throws {
        try await Self.measure("height") { model, n in
            { model.run(n % 2 == 0 ? .tallerTracks : .shorterTracks) }
        }
    }

    /// Runs `prepare` (not timed), then times the event that it returns, `events` times per zoom.
    /// The first 5 events are not timed. Gives the p50 and the max of each zoom.
    @discardableResult
    static func measure(
        _ name: String, zooms: [(String, Double)] = MouseEventBenchmark.zooms, budget: Int = budget, events: Int = 25,
        _ prepare: @MainActor (SessionWindow, Int) -> @MainActor () -> Void
    )
        async throws -> [(p50: Duration, max: Duration)]
    {
        try #require(events > 5, "the first 5 events are not timed")
        var results: [(p50: Duration, max: Duration)] = []
        let folder = try TemporaryFolder()
        let app = AppDelegate(recordings: nil)
        let (session, peaks) = try MouseEventBenchmark.fixture()
        for (n, (zoom, framesPerPoint)) in zooms.enumerated() {
            let package = folder.url.appending(path: "\(n)")
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            let (window, view, model, inputs) = try await MouseEventBenchmark.lanesAndInputs(
                session, peaks, framesPerPoint: framesPerPoint, app: app, folder: package)
            view.viewWillMove(toWindow: nil)
            // The commands of the window model reach the lanes of the test.
            model.timelineView = view
            let studio = try #require(model.studio)
            try #require(window.backingScaleFactor == 2, "this display has scale \(window.backingScaleFactor)")
            var times: [Duration] = []
            for event in 0..<events {
                // The SwiftUI update of the pane: the lane height of the window model over 600 pt.
                func update() {
                    var current = inputs
                    current.laneHeight = model.timeline.laneHeight.points(free: 600, tracks: 6)
                    current.range = model.timeline.waveformRange
                    view.headers.host.rootView = AnyView(
                        TrackHeaders(model: model, studio: studio, laneHeight: current.laneHeight, selected: []))
                    MouseEventBenchmark.swiftUIUpdate(view, model, current)
                }
                let action = prepare(model, event)
                update()
                drawNow(window)
                let draws = view.lanes.draws
                try await Task.sleep(for: .microseconds(16_700))
                // The first events after the window shows are not timed (the backing store and the
                // window server set up: 96 to 225 ms, then 8 to 19 ms), and not in timedSpan.
                if event >= 5 {
                    let start = ContinuousClock.now
                    timedSpan(action, update, window)
                    times.append(ContinuousClock.now - start)
                } else {
                    action()
                    update()
                    drawNow(window)
                }
                try #require(view.lanes.draws > draws, "\(name), \(zoom): event \(event) rendered no lanes")
            }
            let worst = times.max() ?? .zero
            let p50 = times.sorted()[times.count / 2]
            print("NavigationKeyBenchmark \(name), \(zoom): p50 \(p50), max \(worst)")
            expectWithinBudget(worst, .milliseconds(budget), "max: \(name), \(zoom) \(worst)")
            results.append((p50, worst))
            window.close()
            await model.close()
        }
        return results
    }

    /// The timed span of each timed event: the command, the SwiftUI update, and the draw. It is a
    /// function of its own, so a trace keeps only its samples
    /// (`scripts/bench.sh --trace <file> --under timedSpan`).
    @inline(never)
    static func timedSpan(_ action: @MainActor () -> Void, _ update: @MainActor () -> Void, _ window: NSWindow) {
        action()
        update()
        drawNow(window)
    }
}
