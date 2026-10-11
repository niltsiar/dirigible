import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Snap run C12: one drag event with snap on, on the 2 h fixture of `MouseEventBenchmark` plus 200
/// markers, fits one 60 Hz frame, p95 16 ms or less with -O at 2880 x 1200 px (`make bench
/// FILTER=MouseEventSnapBenchmark`). The event is the gesture step with the snap search, the
/// preview edit, the guide layer, and the draw. The paths, each at fit zoom and at the zoom of 60 pt
/// boxes: a move, an end-edge trim, a range drag, and a group drag of "s" and a clip of lane 0 at
/// 1 h (the 0038 budget covers small groups, not Select All). The clip "s" is 200 pt wide on lane 1
/// from x 300 pt. The pointer goes in turn to a
/// point where the moved edge is 2 pt from a marker (it snaps) and to a point 15 pt from it, so each
/// event changes the drawing.
@MainActor struct MouseEventSnapBenchmark {
    enum Path: String, CaseIterable {
        case move, trim, range, group
    }

    /// The fixture with "s" and 200 markers, and the frame of the marker that the path snaps to.
    static func session(_ fixture: Session, _ path: Path, framesPerPoint: Double) throws -> (Session, Frames) {
        var session = fixture
        let frame = { (x: Double) in Frames(Int((x * framesPerPoint).rounded())) }
        let lane = session.tracks[1]
        try session.place(
            Clip(id: "s", file: lane.clips[0].file, start: frame(300), offset: frame(300), length: frame(200)),
            on: lane.id)
        for n in 0..<200 {
            try session.setMarker(
                Marker(
                    id: MarkerID("m\(n)"), name: "M\(n)",
                    position: Frames(n * MouseEventBenchmark.frames / 200 + 9_000),
                    kind: .marker))
        }
        // The target: right of "s" for a move and a range, inside it for a trim of its end.
        let target = frame(path == .trim ? 450 : 400)
        try session.setMarker(Marker(id: "target", name: "Target", position: target, kind: .chapter))
        return (session, target)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aSnapDragEventFitsOneFrameAtTwoHours() async throws {
        let folder = try TemporaryFolder()
        let app = AppDelegate(recordings: nil)
        let (fixture, peaks) = try MouseEventBenchmark.fixture()
        var n = 0
        for path in Path.allCases {
            for (zoom, framesPerPoint) in MouseEventGroupBenchmark.zooms {
                n += 1
                let label = "\(path.rawValue), \(zoom)"
                let package = folder.url.appending(path: "\(n)")
                try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
                let (session, target) = try Self.session(fixture, path, framesPerPoint: framesPerPoint)
                let (sorted, snapped) = try await Self.drags(
                    session, peaks, path, target: target, framesPerPoint: framesPerPoint, app: app, folder: package,
                    label: label)
                print("MouseEventSnapBenchmark \(label): p50 \(sorted[60]), p95 \(sorted[113]), snapped \(snapped)")
                #expect(snapped >= 60, "\(label): \(snapped) of 130 events snapped")
                expectWithinBudget(sorted[113], MouseEventBenchmark.budget, "\(label): p95 \(sorted[113])")
            }
        }
    }

    /// 130 paced drags of `path`; each must draw the lanes once and change a drawn input. Gives the
    /// sorted times of the last 120 and the count of events that showed the guide.
    static func drags(
        _ session: Session, _ peaks: [FileID: PeakState], _ path: Path, target: Frames, framesPerPoint: Double,
        app: AppDelegate, folder: URL, label: String
    ) async throws -> ([Duration], Int) {
        let (window, view, model, first) = try await MouseEventBenchmark.lanesAndInputs(
            session, peaks, framesPerPoint: framesPerPoint, app: app, folder: folder)
        var inputs = first
        app.snaps = true
        try #require(window.backingScaleFactor == 2, "this display has scale \(window.backingScaleFactor)")
        if path == .group {
            let ids: Set<ClipID> = [session.tracks[0].clips[1000].id, "s"]
            model.timeline.selection = .clips(try #require(ClipSet(ids)))
            inputs.selection = model.timeline.selection
            view.update(inputs)
            drawNow(window)
        }
        let box = try #require(view.lanes.clipFrame("s"))
        let targetX = Double(target.count) / framesPerPoint
        // The press and the two pointer x values: the moved edge 2 pt and 15 pt before the target.
        let (down, near, far): (NSPoint, Double, Double) =
            switch path {
            case .move, .group:
                (
                    NSPoint(x: box.minX + 10, y: box.minY + 10), box.minX + 10 + targetX - 2 - box.minX,
                    box.minX + 10 + targetX - 15 - box.minX
                )
            case .trim: (NSPoint(x: box.maxX - 2, y: box.minY + 10), targetX - 2 - 2, targetX - 15 - 2)
            case .range: (NSPoint(x: box.minX - 40, y: 380), targetX - 2, targetX - 15)
            }
        view.lanes.mouseDown(with: try mouse(.leftMouseDown, down, in: view))
        var times: [Duration] = []
        var snapped = 0
        for event in 1...130 {
            let x = event % 2 == 1 ? near : far
            let drag = try mouse(.leftMouseDragged, NSPoint(x: x, y: down.y), in: view)
            let (draws, before) = (view.lanes.draws, view.lanes.inputs)
            try await Task.sleep(for: .microseconds(16_700))
            let start = ContinuousClock.now
            view.lanes.mouseDragged(with: drag)
            if path == .range { MouseEventBenchmark.swiftUIUpdate(view, model, inputs) }
            drawNow(window)
            if event > 10 { times.append(ContinuousClock.now - start) }
            if !view.lanes.guide.isHidden { snapped += 1 }
            try #require(view.lanes.draws == draws + 1, "\(label): event \(event) drew \(view.lanes.draws - draws)")
            try #require(view.lanes.inputs != before, "\(label): event \(event) changed no drawn input")
        }
        view.lanes.mouseUp(with: try mouse(.leftMouseUp, down, in: view))
        window.close()
        await model.close()
        return (times.sorted(), snapped)
    }
}
