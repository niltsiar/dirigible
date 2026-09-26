import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Mouse-edits criterion 15, the drags whose redraw is more than the boxes of a narrow clip (code
/// gate 1 item 2): a range drag and a triangle drag (new Marks through SwiftUI), a move of the last
/// clip (a new width), and a move of a clip wider than the view (every column of its lanes).
extension MouseEventBenchmark {
    /// The update of SwiftUI after a change of the Marks: `laneInputs(_:_:laneHeight:)` of the app
    /// gives the Studio session and the Marks of the window model. The Studio has the peaks of its
    /// 1 s package, so the call keeps the 2 h peaks of `inputs`.
    static func swiftUIUpdate(_ view: TimelineScrollView, _ model: SessionWindow, _ inputs: LaneInputs) {
        guard let studio = model.studio else { return }
        var new = laneInputs(model, studio, laneHeight: inputs.laneHeight)
        (new.peaks, new.missingMedia) = (inputs.peaks, inputs.missingMedia)
        view.update(new)
    }

    /// One range drag event in the lanes: the gesture step, the Marks in the window model, the
    /// SwiftUI update with the new Marks, and the draw. It starts in the lower third of lane 1 at
    /// x 330 pt (at the zoom of 60 pt boxes, 30 pt from each edge: 4 pt at an edge trims); each event
    /// takes the end 1 pt right and to the other of lanes 1 and 2.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aRangeDragEventFitsOneFrameAtTwoHours() async throws {
        let folder = try TemporaryFolder()
        let app = AppDelegate(recordings: nil)
        let (session, peaks) = try Self.fixture()
        for (n, (zoom, framesPerPoint)) in Self.zooms.enumerated() {
            let package = folder.url.appending(path: "\(n)")
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            let (window, view, model, inputs) = try await Self.lanesAndInputs(
                session, peaks, framesPerPoint: framesPerPoint, app: app, folder: package)
            try #require(window.backingScaleFactor == 2, "this display has scale \(window.backingScaleFactor)")
            let down = NSPoint(x: 330, y: 80)
            view.lanes.mouseDown(with: try mouse(.leftMouseDown, down, in: view))
            let sorted = try await Self.pacedDrags(
                view, window, zoom, swiftUI: (model, inputs)
            ) { event in
                try mouse(
                    .leftMouseDragged, NSPoint(x: down.x + Double(3 + event), y: down.y + (event % 2 == 0 ? 0 : 100)),
                    in: view)
            }
            view.lanes.mouseUp(with: try mouse(.leftMouseUp, down, in: view))
            print("MouseEventBenchmark range, \(zoom): p50 \(sorted[60]), p95 \(sorted[113])")
            #expect(sorted[113] <= Self.budget, "\(zoom): p95 \(sorted[113])")
            window.close()
            await model.close()
        }
    }

    /// One in-triangle drag event on the ruler: as the range case, with the Marks of x 300 to 900 pt
    /// on all tracks. Each event takes the in point 1 pt right.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aTriangleDragEventFitsOneFrameAtTwoHours() async throws {
        let folder = try TemporaryFolder()
        let app = AppDelegate(recordings: nil)
        let (session, peaks) = try Self.fixture()
        for (n, (zoom, framesPerPoint)) in Self.zooms.enumerated() {
            let package = folder.url.appending(path: "\(n)")
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            let (window, view, model, inputs) = try await Self.lanesAndInputs(
                session, peaks, framesPerPoint: framesPerPoint, app: app, folder: package)
            try #require(window.backingScaleFactor == 2, "this display has scale \(window.backingScaleFactor)")
            model.timeline.marks = Marks(
                inPoint: Frames(Int(framesPerPoint * 300)), outPoint: Frames(Int(framesPerPoint * 900)),
                tracks: Set(session.tracks.map(\.id)))
            Self.swiftUIUpdate(view, model, inputs)
            drawNow(window)
            view.ruler.mouseDown(with: try rulerMouse(.leftMouseDown, 300, 20, in: view))
            let sorted = try await Self.pacedDrags(
                view, window, zoom, to: view.ruler, swiftUI: (model, inputs)
            ) { event in
                try rulerMouse(.leftMouseDragged, 300 + Double(3 + event), 20, in: view)
            }
            view.ruler.mouseUp(with: try rulerMouse(.leftMouseUp, 300, 20, in: view))
            print("MouseEventBenchmark triangle, \(zoom): p50 \(sorted[60]), p95 \(sorted[113])")
            #expect(sorted[113] <= Self.budget, "\(zoom): p95 \(sorted[113])")
            window.close()
            await model.close()
        }
    }

    /// One move event of the last clip of the session: each event changes the session end. The
    /// lanes keep their width until the up. The clip "end" (20 pt at each zoom) ends t2 at the session end, and
    /// the lanes in view end at the end of the lanes. Each event takes the clip 3 to 12 pt right of
    /// the down, a new end at each event. The clip is narrower than the view, so the event measures
    /// the new width, not the redraw of a clip wider than the view.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func anEndClipMoveEventFitsOneFrameAtTwoHours() async throws {
        let folder = try TemporaryFolder()
        let app = AppDelegate(recordings: nil)
        let (fixture, peaks) = try Self.fixture()
        let end = Frames(Self.frames)
        for (n, (zoom, framesPerPoint)) in Self.zooms.enumerated() {
            var session = fixture
            let length = Frames(Int(framesPerPoint * 20))
            try session.place(
                Clip(id: "end", file: "f2", start: end - length, offset: end - length, length: length), on: "t2")
            let package = folder.url.appending(path: "\(n)")
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            let (window, view, model) = try await Self.lanesOnScreen(
                session, peaks, framesPerPoint: framesPerPoint, app: app, folder: package)
            try #require(window.backingScaleFactor == 2, "this display has scale \(window.backingScaleFactor)")
            view.scroll(toFrame: Double(Self.frames) - 1400 * framesPerPoint)
            drawNow(window)
            let box = try #require(view.lanes.clipFrame("end"))
            let down = NSPoint(x: box.maxX - 10, y: box.minY + 10)
            try #require(view.shown.contains(down), "\(zoom): \(down) not in \(view.shown)")
            let width = view.lanes.frame.width
            view.lanes.mouseDown(with: try mouse(.leftMouseDown, down, in: view))
            let sorted = try await Self.pacedDrags(view, window, zoom) { event in
                try mouse(.leftMouseDragged, NSPoint(x: down.x + Double(3 + event % 10), y: down.y), in: view)
            }
            try #require(view.lanes.frame.width == width, "\(zoom): the lanes keep their width in the drag")
            view.lanes.mouseUp(with: try mouse(.leftMouseUp, NSPoint(x: down.x + 12, y: down.y), in: view))
            try #require(view.lanes.frame.width > width, "\(zoom): the up gives the new width")
            print("MouseEventBenchmark end move, \(zoom): p50 \(sorted[60]), p95 \(sorted[113])")
            #expect(sorted[113] <= Self.budget, "\(zoom): p95 \(sorted[113])")
            window.close()
            await model.close()
        }
    }

    /// One move event of a clip wider than the view: every column in view of its lane changes, so
    /// the event redraws the rows of that lane only. The clip "wide" on t2 is x 20 to 1420 pt at fit
    /// zoom, x 100 to 2100 pt at the zoom of 60 pt boxes. With `laneChange`, each event also takes it
    /// to the other of t2 and t3, so the event redraws the rows of both lanes. Each event takes it
    /// 1 pt right.
    func wideClipMoves(laneChange: Bool) async throws {
        let folder = try TemporaryFolder()
        let app = AppDelegate(recordings: nil)
        let (fixture, peaks) = try Self.fixture()
        for (n, (zoom, framesPerPoint)) in Self.zooms.enumerated() {
            var session = fixture
            let (start, width) = n == 0 ? (20.0, 1400.0) : (100.0, 2000.0)
            let clip = Clip(
                id: "wide", file: "f2", start: Frames(Int(framesPerPoint * start)), offset: 0,
                length: Frames(Int(framesPerPoint * width)))
            try session.place(clip, on: "t2")
            let package = folder.url.appending(path: "\(n)")
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            let (window, view, model) = try await Self.lanesOnScreen(
                session, peaks, framesPerPoint: framesPerPoint, app: app, folder: package)
            try #require(window.backingScaleFactor == 2, "this display has scale \(window.backingScaleFactor)")
            if n == 1 {
                view.scroll(toFrame: framesPerPoint * (start - 10))
                drawNow(window)
            }
            let box = try #require(view.lanes.clipFrame("wide"))
            try #require(box.minX < view.shown.minX + 30 && box.maxX > view.shown.maxX - 30, "\(zoom): \(box)")
            let down = NSPoint(x: view.shown.minX + 300, y: box.minY + 10)
            view.lanes.mouseDown(with: try mouse(.leftMouseDown, down, in: view))
            let sorted = try await Self.pacedDrags(view, window, zoom) { event in
                let y = down.y + (laneChange && event % 2 == 1 ? 100 : 0)
                return try mouse(.leftMouseDragged, NSPoint(x: down.x + Double(3 + event), y: y), in: view)
            }
            view.lanes.mouseUp(with: try mouse(.leftMouseUp, down, in: view))
            let name = laneChange ? "wide lane change" : "wide move"
            print("MouseEventBenchmark \(name), \(zoom): p50 \(sorted[60]), p95 \(sorted[113])")
            #expect(sorted[113] <= Self.budget, "\(zoom): p95 \(sorted[113])")
            window.close()
            await model.close()
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aWideClipMoveEventFitsOneFrameAtTwoHours() async throws {
        try await wideClipMoves(laneChange: false)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aWideClipLaneChangeEventFitsOneFrameAtTwoHours() async throws {
        try await wideClipMoves(laneChange: true)
    }
}
