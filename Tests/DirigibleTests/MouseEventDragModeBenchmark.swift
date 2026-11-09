import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp

/// C60 of run `2026-10-28-timeline-edits` (drag modes), optimized (`make bench
/// FILTER=MouseEventDragModeBenchmark`): one drag event in Shuffle, No Overlap, or Crossfade mode
/// (the gesture step, the preview edit, and the draw) fits one 60 Hz frame (p95 16 ms or less) on
/// the 2 h fixture of `MouseEventBenchmark`. Paths 1 to 3 take the first clip of t1: at fit zoom
/// the 20 pt clip "big" at frame 0 (a fixture clip is 0.72 pt, all range zone), at the zoom of
/// 60 pt boxes the first fixture clip. Paths 4 and 5 take a clip near x 300 pt: "big" at frame
/// 100,000,000, or the fixture clip at frame 864,000. Path 4 removes the two neighbors of its clip,
/// so the events stop at the left and at the right neighbor in turn.
@MainActor struct MouseEventDragModeBenchmark {
    static let zooms = [
        ("fit, not whole", Double(MouseEventBenchmark.frames) / 1439.3),
        ("60 pt boxes", Double(MouseEventBenchmark.frames / 2000) / 60),
    ]

    struct Path {
        let name: String
        let mode: DragMode
        /// True for a press on the end edge, else on the clip body.
        let edge: Bool
        /// True for the clip near x 300 pt, else the first clip of t1.
        let middle: Bool
        /// Paths 1 and 2: a row of the first drag event of each press (the close of C57, U57).
        let firstEvent: Bool
        /// The point of drag event `n` from the down point and the box width.
        let point: (_ n: Int, _ down: NSPoint, _ width: Double) -> NSPoint
    }

    static let paths = [
        Path(name: "shuffle on t1", mode: .shuffle, edge: false, middle: false, firstEvent: true) { n, down, width in
            NSPoint(x: down.x + width * (n % 2 == 0 ? 1.3 : 3.3), y: down.y)
        },
        Path(name: "shuffle to t6", mode: .shuffle, edge: false, middle: false, firstEvent: true) { n, down, width in
            NSPoint(x: down.x + width * (n % 2 == 0 ? 1.3 : 3.3), y: down.y + 500)
        },
        Path(name: "shuffle edge", mode: .shuffle, edge: true, middle: false, firstEvent: false) { n, down, _ in
            NSPoint(x: down.x - Double(3 + n % 10), y: down.y)
        },
        Path(name: "no overlap stop", mode: .noOverlap, edge: false, middle: true, firstEvent: false) {
            n, down, width in NSPoint(x: down.x + (n % 2 == 0 ? -1 : 1) * (width + 100), y: down.y)
        },
        Path(name: "crossfade", mode: .crossfade, edge: false, middle: true, firstEvent: false) { n, down, width in
            NSPoint(x: down.x + width * (n % 2 == 0 ? 0.3 : 0.5), y: down.y)
        },
    ]

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func eachDragModeEventFitsOneFrameAtTwoHours() async throws {
        let folder = try TemporaryFolder()
        let app = AppDelegate(recordings: nil)
        let (fixture, peaks) = try MouseEventBenchmark.fixture()
        for (p, path) in Self.paths.enumerated() {
            for (z, (zoom, framesPerPoint)) in Self.zooms.enumerated() {
                let row = "\(path.name), \(zoom)"
                let (session, mover) = try Self.session(fixture, path, fit: z == 0)
                let package = folder.url.appending(path: "\(p)-\(z)")
                try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
                app.dragMode = path.mode
                let (window, view, model, _) = try await MouseEventBenchmark.lanesAndInputs(
                    session, peaks, framesPerPoint: framesPerPoint, app: app, folder: package)
                try #require(window.backingScaleFactor == 2, "this display has scale \(window.backingScaleFactor)")
                let box = try #require(view.lanes.clipFrame(mover))
                try #require(box.width >= 12 && box.maxX < 1300, "\(row): \(box)")
                let down = NSPoint(x: path.edge ? box.maxX - 2 : box.midX, y: box.minY + 10)
                if path.firstEvent {
                    let sorted = try await Self.firstEvents(view, window, row, down) { path.point(1, down, box.width) }
                    print(
                        "MouseEventDragModeBenchmark \(path.name) first event, \(zoom): p50 \(sorted[60]),"
                            + " p95 \(sorted[113])")
                    let p95 = sorted[113]
                    expectWithinBudget(p95, MouseEventBenchmark.budget, "\(row) first event: p95 \(p95)")
                }
                let shown = try #require(view.lanes.surfaces.shown)
                let otherLanes = shown.rows(of: 1..<5)
                var wideDraws = 0
                let shiftedBefore = view.lanes.surfaces.shifted
                view.lanes.mouseDown(with: try mouse(.leftMouseDown, down, in: view))
                let sorted = try await MouseEventBenchmark.pacedDrags(view, window, row) { n in
                    // The draw of event n - 1: a draw 360 pt wide or more keeps off the rows of t2 to
                    // t5. A narrower change draws all lanes of its columns.
                    let drawn = view.lanes.surfaces.lastDrawn
                    let low = drawn.map(\.columns.lowerBound).min() ?? 0
                    let high = drawn.map(\.columns.upperBound).max() ?? 0
                    if n > 1, Double(high - low) >= 360 * shown.scale,
                        drawn.contains(where: { $0.rows.overlaps(otherLanes) })
                    {
                        wideDraws += 1
                    }
                    return try mouse(.leftMouseDragged, path.point(n, down, box.width), in: view)
                }
                view.lanes.mouseUp(with: try mouse(.leftMouseUp, down, in: view))
                let shifted = view.lanes.surfaces.shifted - shiftedBefore
                print(
                    "MouseEventDragModeBenchmark \(path.name), \(zoom): p50 \(sorted[60]), p95 \(sorted[113]),"
                        + " shifted \(shifted), wide draws on t2 to t5 \(wideDraws)")
                expectWithinBudget(sorted[113], MouseEventBenchmark.budget, "\(row): p95 \(sorted[113])")
                // The time-free counts of C60 (U48, U49), after the print, so a miss keeps the times.
                if path.edge { #expect(shifted >= 120, "\(row): \(shifted) events drew by a shift") }
                if path.name == "shuffle to t6" {
                    #expect(wideDraws == 0, "\(row): \(wideDraws) events drew t2 to t5 over 360 pt or more")
                }
                window.close()
                await model.close()
            }
        }
    }

    /// The session of a path and the clip that it drags.
    static func session(_ fixture: Session, _ path: Path, fit: Bool) throws -> (Session, ClipID) {
        var session = fixture
        let mover: ClipID
        if fit {
            let start = Frames(path.middle ? 100_000_000 : 0)
            try session.place(Clip(id: "big", file: "f1", start: start, offset: start, length: 4_800_000), on: "t1")
            mover = "big"
        } else {
            let start = Frames(path.middle ? 864_000 : 0)
            mover = try #require(session.tracks[0].clips.first { $0.start == start }).id
        }
        if path.mode == .noOverlap {
            let clip = try #require(session.clip(mover)).clip
            let neighbors = session.tracks[0].clips.filter { $0.end == clip.start || $0.start == clip.end }
            try #require(neighbors.count == 2, "\(path.name): neighbors \(neighbors.map(\.id))")
            try session.removeClips(neighbors.map(\.id))
        }
        return (session, mover)
    }

    /// The first drag event of 130 presses, one per 60 Hz frame, and the sorted times of the last 120:
    /// the event and its draw. Esc ends each press with no commit, so each press starts from the same
    /// session.
    static func firstEvents(
        _ view: TimelineScrollView, _ window: NSWindow, _ row: String, _ down: NSPoint, _ point: () -> NSPoint
    ) async throws -> [Duration] {
        var times: [Duration] = []
        for n in 1...130 {
            view.lanes.mouseDown(with: try mouse(.leftMouseDown, down, in: view))
            let (drag, before) = (try mouse(.leftMouseDragged, point(), in: view), view.lanes.inputs)
            try await Task.sleep(for: .microseconds(16_700))
            let start = ContinuousClock.now
            view.lanes.mouseDragged(with: drag)
            drawNow(window)
            if n > 10 { times.append(ContinuousClock.now - start) }
            try #require(view.lanes.inputs != before, "\(row): press \(n) changed no drawn input")
            try #require(view.cancelGesture(), "\(row): press \(n) had no gesture at Esc")
            view.lanes.mouseUp(with: try mouse(.leftMouseUp, down, in: view))
            drawNow(window)
        }
        return times.sorted()
    }
}
