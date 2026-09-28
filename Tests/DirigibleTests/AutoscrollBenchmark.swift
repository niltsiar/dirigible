import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Timeline-navigation criterion N23, a new path of the 0020 list: one autoscroll tick during a
/// clip move with a still pointer 40 pt past the right edge fits one 60 Hz frame, 16 ms p95 with
/// -O (`make bench FILTER=MouseEventBenchmark`; 100 ms in debug). A tick is the scroll, the drag
/// event again at the same point (the gesture step and the preview), and the render. At the fit
/// the lanes are the view and cannot scroll, so the cases are a fixture clip and a clip wider than
/// the view, both at 60 pt boxes. Each tick must scroll and render the lanes once.
extension MouseEventBenchmark {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func anAutoscrollTickFitsOneFrame() async throws {
        let folder = try TemporaryFolder()
        let app = AppDelegate(recordings: nil)
        var (session, peaks) = try Self.fixture()
        try session.place(
            Clip(id: "big", file: "f2", start: 100_000_000, offset: 100_000_000, length: 4_800_000), on: "t2")
        let framesPerPoint = Self.zooms[1].1
        for (n, name) in ["clip", "wide clip"].enumerated() {
            let package = folder.url.appending(path: "\(n)")
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            let (window, view, model) = try await Self.lanesOnScreen(
                session, peaks, framesPerPoint: framesPerPoint, app: app, folder: package)
            view.viewWillMove(toWindow: nil)
            try #require(window.backingScaleFactor == 2, "this display has scale \(window.backingScaleFactor)")
            let clipStart = n == 0 ? 300.0 : 100_000_000 / framesPerPoint
            view.scroll(toFrame: (clipStart - 100) * framesPerPoint)
            drawNow(window)
            let down = NSPoint(x: clipStart + 30, y: n == 0 ? 10 : 110)
            view.lanes.mouseDown(with: try mouse(.leftMouseDown, down, in: view))
            view.lanes.mouseDragged(
                with: try mouse(.leftMouseDragged, NSPoint(x: Double(view.shown.maxX) + 40, y: down.y), in: view))
            drawNow(window)
            var times: [Duration] = []
            let start = CACurrentMediaTime()
            for tick in 1...130 {
                let (origin, draws) = (view.origin, view.lanes.draws)
                try await Task.sleep(for: .microseconds(16_700))
                let begin = ContinuousClock.now
                view.autoscrollTick(at: start + Double(tick) / 60)
                drawNow(window)
                if tick > 10 { times.append(ContinuousClock.now - begin) }
                try #require(view.origin > origin, "\(name): tick \(tick) did not scroll")
                try #require(
                    view.lanes.draws == draws + 1, "\(name): tick \(tick) drew \(view.lanes.draws - draws) times")
            }
            _ = view.cancelGesture()
            let sorted = times.sorted()
            print("MouseEventBenchmark autoscroll, \(name): p50 \(sorted[60]), p95 \(sorted[113])")
            #expect(sorted[113] <= Self.budget, "\(name): p95 \(sorted[113])")
            window.close()
            await model.close()
        }
    }
}
