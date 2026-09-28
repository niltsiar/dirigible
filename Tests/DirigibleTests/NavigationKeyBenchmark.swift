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

    /// Runs `prepare` (not timed), then times the event that it returns, 25 times per zoom.
    static func measure(_ name: String, _ prepare: @MainActor (SessionWindow, Int) -> @MainActor () -> Void)
        async throws
    {
        let folder = try TemporaryFolder()
        let app = AppDelegate(recordings: nil)
        let (session, peaks) = try MouseEventBenchmark.fixture()
        for (n, (zoom, framesPerPoint)) in MouseEventBenchmark.zooms.enumerated() {
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
            for event in 0..<25 {
                let action = prepare(model, event)
                MouseEventBenchmark.swiftUIUpdate(view, model, inputs)
                drawNow(window)
                let draws = view.lanes.draws
                try await Task.sleep(for: .microseconds(16_700))
                let start = ContinuousClock.now
                action()
                view.headers.host.rootView = AnyView(TrackHeaders(model: model, studio: studio, laneHeight: 100))
                MouseEventBenchmark.swiftUIUpdate(view, model, inputs)
                drawNow(window)
                // The first events after the window shows are not timed (the backing store and the
                // window server set up: 96 to 225 ms, then 8 to 19 ms).
                if event >= 5 { times.append(ContinuousClock.now - start) }
                try #require(view.lanes.draws > draws, "\(name), \(zoom): event \(event) rendered no lanes")
            }
            let worst = times.max() ?? .zero
            print("NavigationKeyBenchmark \(name), \(zoom): p50 \(times.sorted()[10]), max \(worst)")
            #expect(worst <= .milliseconds(budget), "max over \(budget) ms: \(name), \(zoom) \(worst)")
            window.close()
            await model.close()
        }
    }
}
