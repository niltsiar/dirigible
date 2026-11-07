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
/// zoom of 60 pt boxes, the first fixture clip of t1 takes it. The follow bed row (C53 of run
/// `2026-10-28-timeline-edits`, decision 0073) adds a track that follows ripples with one clip over
/// the whole fixture, so its lane does not move and draws in its own strip.
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
        func withBed(_ session: Session) throws -> Session {
            var session = session
            let length = Frames(MouseEventBenchmark.frames)
            try session.addFile(AudioFile(id: "fbed", path: "bed.wav", layout: .mono, length: length))
            try session.addTrack("bed", name: "Bed", layout: .mono)
            try session.place(Clip(id: "bed", file: "fbed", start: 0, offset: 0, length: length), on: "bed")
            try session.setFollowTrack(true, tracks: ["bed"])
            return session
        }
        peaks["fbed"] = peaks["f1"]
        // A real fit is not a whole number of frames per point (code gate 1 item 1).
        let zooms = MouseEventBenchmark.zooms + [("fit, not whole", Double(MouseEventBenchmark.frames) * 1.02 / 1437)]
        let rows = [false, true].flatMap { bed in zooms.enumerated().map { ($0.offset, $0.element, bed) } }
        for (n, (zoom, framesPerPoint), bed) in rows {
            let plain = n != 1 ? withBig : session
            let shown = bed ? try withBed(plain) : plain
            let zoom = bed ? "\(zoom), follow bed" : zoom
            let package = folder.url.appending(path: bed ? "bed\(n)" : "\(n)")
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            let (window, view, model, inputs) = try await MouseEventBenchmark.lanesAndInputs(
                shown, peaks, framesPerPoint: framesPerPoint, app: app, folder: package)
            try #require(window.backingScaleFactor == 2, "this display has scale \(window.backingScaleFactor)")
            let first = try #require(shown.tracks[0].clips.first)
            let box = try #require(view.lanes.clipFrame(first.id))
            try #require(box.width >= 12 && box.maxX < 1300, "\(zoom): \(box)")
            let down = NSPoint(x: box.maxX - 2, y: box.minY + 10)
            // The Marks of a ripple commit are on the clip: the state of a second drag.
            var marked = inputs
            marked.selection = .range(Marks(inPoint: first.start, outPoint: first.end, tracks: ["t1"]))
            model.timeline.selection = marked.selection
            view.update(marked)
            drawNow(window)
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
            try #require(
                view.lanes.surfaces.shifted >= 120, "\(zoom): \(view.lanes.surfaces.shifted) events drew by a shift")
            print(
                "MouseEventRippleBenchmark ripple trim, \(zoom): p50 \(sorted[60]), p95 \(sorted[113]),"
                    + " shifted \(view.lanes.surfaces.shifted), made \(view.lanes.surfaces.made)")
            expectWithinBudget(sorted[113], MouseEventBenchmark.budget, "\(zoom): p95 \(sorted[113])")
            window.close()
            await model.close()
        }
    }
}
