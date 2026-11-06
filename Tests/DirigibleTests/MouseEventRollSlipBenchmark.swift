import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp

/// C27 of run 2026-10-28-timeline-edits (decision 0020), optimized
/// (`make bench FILTER=MouseEventRollSlipBenchmark`): one roll or slip drag event (the gesture step,
/// the preview `roll` or `slip`, and the lane draw) fits one 60 Hz frame (p95 16 ms or less) on the
/// 2 h fixture of `MouseEventCrossfadeBenchmark`. The press has Shift and Command down. The paths: a
/// roll of the join of "big" and "big2" on t2, and a slip of "big", at fit zoom and at fit zoom
/// with a fraction of frames per point; at 60 pt boxes a roll of the t2 join at x 360 and a slip of
/// the t2 clip at x 300 to 360; and a slip of "wide" (1,736 pt at 60 pt boxes) on t3.
@MainActor struct MouseEventRollSlipBenchmark {
    private static let flags: NSEvent.ModifierFlags = [.shift, .command]

    /// One path: where the press lands, which way the drag goes, and the value that each event must
    /// change. `drawsNarrow` paths also assert that no event redraws a wide part of the lanes.
    private struct Path {
        let name: String
        let down: NSPoint
        let direction: Double
        let probe: @MainActor (Session) -> Frames?
        let drawsNarrow: Bool
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aRollOrSlipEventFitsOneFrameAtTwoHours() async throws {
        let folder = try TemporaryFolder()
        let app = AppDelegate(recordings: nil)
        var (session, peaks) = try MouseEventCrossfadeBenchmark.fixture()
        try session.place(Clip(id: "wide", file: "f3", start: 0, offset: 1_000_000, length: 5_000_000), on: "t3")
        // A real fit is not a whole number of frames per point.
        let zooms = MouseEventBenchmark.zooms + [("fit, not whole", Double(MouseEventBenchmark.frames) * 1.02 / 1437)]
        for (n, (zoom, framesPerPoint)) in zooms.enumerated() {
            let package = folder.url.appending(path: "\(n)")
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            let (window, view, model, _) = try await MouseEventBenchmark.lanesAndInputs(
                session, peaks, framesPerPoint: framesPerPoint, app: app, folder: package)
            try #require(window.backingScaleFactor == 2, "this display has scale \(window.backingScaleFactor)")
            for path in try Self.paths(zoom, view) {
                let down = path.down
                view.lanes.mouseDown(with: try mouse(.leftMouseDown, down, in: view, flags: Self.flags))
                var values: [Frames] = []
                var rects: [NSRect] = []
                var last = down
                let sorted = try await MouseEventBenchmark.pacedDrags(view, window, "\(zoom) \(path.name)") { event in
                    if let value = view.lanes.inputs.flatMap({ path.probe($0.session) }) { values.append(value) }
                    if event > 2 { rects.append(view.lanes.drawnRect) }
                    last = NSPoint(x: down.x + path.direction * Double(3 + event % 10), y: down.y)
                    return try mouse(.leftMouseDragged, last, in: view)
                }
                view.lanes.mouseUp(with: try mouse(.leftMouseUp, last, in: view))
                // After the clock: each event took the join or the offset to a new place, and a
                // narrow path drew a part of the lanes, not the 1,440 pt in view.
                try #require(values.count >= 128, "\(zoom) \(path.name): no value to read")
                try #require(
                    zip(values.dropFirst(2), values.dropFirst(3)).allSatisfy { $0 != $1 },
                    "\(zoom) \(path.name): an event kept the value")
                if path.drawsNarrow {
                    let widest = rects.map(\.width).max() ?? .infinity
                    try #require(widest < 360, "\(zoom) \(path.name): an event drew \(widest) pt")
                }
                print(
                    "MouseEventRollSlipBenchmark \(path.name), \(zoom): p50 \(sorted[60]), p95 \(sorted[113]),"
                        + " widest draw \(rects.map(\.width).max() ?? 0) pt")
                expectWithinBudget(sorted[113], MouseEventBenchmark.budget, "\(zoom) \(path.name): p95 \(sorted[113])")
            }
            window.close()
            await model.close()
        }
    }

    /// The paths of one zoom. At the two fit zooms a box is under 1 pt, so the clips "big" and
    /// "big2" of t2 take the press; at 60 pt boxes the fixture clips of t2 at x 300 and 360 do.
    private static func paths(_ zoom: String, _ view: TimelineScrollView) throws -> [Path] {
        let session = try #require(view.lanes.inputs?.session)
        let t2 = session.tracks[1].clips
        func clip(holding x: Double) throws -> Clip {
            t2[try #require(t2.index(holding: Frames(Int(x * view.lanes.framesPerPoint))))]
        }
        if zoom == "60 pt boxes" {
            let joined = try clip(holding: 358)
            let slipped = try clip(holding: 330)
            return [
                Path(
                    name: "slip t2", down: NSPoint(x: 330, y: 130), direction: 1,
                    probe: { $0.clip(slipped.id)?.clip.offset }, drawsNarrow: true),
                Path(
                    name: "roll t2", down: NSPoint(x: 358, y: 110), direction: -1,
                    probe: { $0.clip(joined.id)?.clip.end }, drawsNarrow: true),
                Path(
                    name: "slip wide", down: NSPoint(x: 700, y: 230), direction: 1,
                    probe: { $0.clip("wide")?.clip.offset }, drawsNarrow: false),
            ]
        }
        let big = try #require(view.lanes.clipFrame("big"))
        try #require(big.width >= 12 && big.maxX < 1300, "\(zoom): \(big)")
        return [
            Path(
                name: "slip big", down: NSPoint(x: big.midX, y: big.minY + 30), direction: 1,
                probe: { $0.clip("big")?.clip.offset }, drawsNarrow: false),
            Path(
                name: "roll big", down: NSPoint(x: big.maxX - 2, y: big.minY + 10), direction: -1,
                probe: { $0.clip("big")?.clip.end }, drawsNarrow: false),
        ]
    }
}
