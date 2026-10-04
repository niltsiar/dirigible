import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp

/// C14a of run 12 (decision 0037), optimized (`make bench FILTER=MouseEventRippleBenchmark`): one
/// ripple trim drag event (the gesture step, the preview `rippleTrim` on 6 tracks, and the draw)
/// fits one 60 Hz frame (p95 16 ms or less) on the 2 h fixture with 100 markers. The press takes
/// the end of the first clip of t1 with Option, so every later clip of each track moves. At fit
/// zoom a box is 0.72 pt, so clip "big" of 4,800,000 frames (20 pt) at frame 0 on t1 takes it. At the
/// zoom of 60 pt boxes, the first fixture clip of t1 takes it.
@MainActor struct MouseEventRippleBenchmark {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aRippleTrimEventFitsOneFrameAtTwoHours() async throws {
        let folder = try TemporaryFolder()
        let app = AppDelegate(recordings: nil)
        var (session, peaks) = try MouseEventBenchmark.fixture()
        for n in 0..<100 {
            try session.setMarker(
                Marker(id: MarkerID("m\(n)"), name: "M\(n)", position: Frames(n * 3_456_000), kind: .marker))
        }
        var withBig = session
        try withBig.place(Clip(id: "big", file: "f1", start: 0, offset: 0, length: 4_800_000), on: "t1")
        for (n, (zoom, framesPerPoint)) in MouseEventBenchmark.zooms.enumerated() {
            let shown = n == 0 ? withBig : session
            let package = folder.url.appending(path: "\(n)")
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            let (window, view, model) = try await MouseEventBenchmark.lanesOnScreen(
                shown, peaks, framesPerPoint: framesPerPoint, app: app, folder: package)
            try #require(window.backingScaleFactor == 2, "this display has scale \(window.backingScaleFactor)")
            let first = try #require(shown.tracks[0].clips.first)
            let box = try #require(view.lanes.clipFrame(first.id))
            try #require(box.width >= 12 && box.maxX < 1300, "\(zoom): \(box)")
            let down = NSPoint(x: box.maxX - 2, y: box.minY + 10)
            view.lanes.mouseDown(with: try mouse(.leftMouseDown, down, in: view, flags: .option))
            var ends: [Frames] = []
            let sorted = try await MouseEventBenchmark.pacedDrags(view, window, zoom) { event in
                if let end = view.lanes.inputs?.session.clip(first.id)?.clip.end { ends.append(end) }
                return try mouse(.leftMouseDragged, NSPoint(x: down.x - Double(3 + event % 10), y: down.y), in: view)
            }
            view.lanes.mouseUp(with: try mouse(.leftMouseUp, down, in: view))
            // After the clock: each event took the trimmed end to a new place.
            try #require(
                zip(ends.dropFirst(2), ends.dropFirst(3)).allSatisfy { $0 != $1 }, "\(zoom): an event kept the end")
            print("MouseEventRippleBenchmark ripple trim, \(zoom): p50 \(sorted[60]), p95 \(sorted[113])")
            expectWithinBudget(sorted[113], MouseEventBenchmark.budget, "\(zoom): p95 \(sorted[113])")
            window.close()
            await model.close()
        }
    }
}
