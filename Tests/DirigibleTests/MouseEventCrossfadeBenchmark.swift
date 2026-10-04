import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// B1 of run 11c-2 on the 2 h fixture, optimized (`make bench FILTER=MouseEventCrossfadeBenchmark`):
/// one crossfade-handle drag event fits one 60 Hz frame (p95 16 ms or less), its mouse-up and the
/// double-click fit two frames, and its p50 is not more than 10 % or 1 ms (the larger) over the
/// fade-handle drag p50 of `MouseEventGainBenchmark` in the same run. The fixture is
/// `joinedFixture` with a crossfade of 960 frames at each join. At the zoom of 60 pt boxes, the
/// press takes the handle of the join at x 360 on t2. At fit zoom a box is 0.72 pt, so two joined
/// clips of 12,000,000 frames (50 pt) on t2, "big" and "big2", with a crossfade of 4,800,000 frames
/// (10 pt on each side), take the press.
@MainActor struct MouseEventCrossfadeBenchmark {
    static func fixture() throws -> (Session, [FileID: PeakState]) {
        var session = try MouseEventBenchmark.joinedFixture()
        let lengths = session.tracks.flatMap { $0.clips.dropLast().map { ($0.id, Frames(960)) } }
        try session.setCrossfades(Dictionary(uniqueKeysWithValues: lengths))
        try session.place(
            Clip(id: "big", file: "f2", start: 100_000_000, offset: 100_000_000, length: 12_000_000), on: "t2")
        try session.place(
            Clip(id: "big2", file: "f3", start: 112_000_000, offset: 50_000_000, length: 12_000_000), on: "t2")
        try session.setCrossfades(["big": 4_800_000])
        let peaks = PeakState.ready(randomPeaks(frames: MouseEventBenchmark.frames))
        return (session, Dictionary(uniqueKeysWithValues: (1...6).map { (FileID("f\($0)"), peaks) }))
    }

    /// The press on the end handle of the box at the end of its crossfade half; each event takes
    /// the handle 3 to 12 pt left, a new length. Then the mouse-up commit, and a double-click on
    /// the handle at its new place that removes the crossfade. After the clock stops, each step
    /// asserts its change.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aCrossfadeHandleDragEventFitsOneFrameAtTwoHours() async throws {
        let fade = try await MouseEventGainBenchmark.fadeDrag()
        let (session, peaks) = try Self.fixture()
        var p50: [Duration] = []
        try await MouseEventGainBenchmark.eachZoom(session, peaks) { zoom, window, view, box in
            @MainActor func clip() throws -> Clip {
                let clips = try #require(view.lanes.inputs?.session.tracks[1].clips)
                return clips[try #require(clips.index(holding: Frames(Int(box.midX * view.lanes.framesPerPoint))))]
            }
            let start = try clip().crossfades.end
            try #require(start > .zero, "\(zoom): no crossfade at the end of the box")
            let half = Double(start.count / 2) / view.lanes.framesPerPoint
            // The handle center is the end of the half, kept 4 pt inside the box.
            let down = NSPoint(x: min(max(box.maxX - half, box.minX + 4), box.maxX - 4), y: box.minY + 4)
            view.lanes.mouseDown(with: try mouse(.leftMouseDown, down, in: view))
            let sorted = try await MouseEventBenchmark.pacedDrags(view, window, zoom) { event in
                try mouse(.leftMouseDragged, NSPoint(x: down.x - Double(3 + event % 10), y: down.y), in: view)
            }
            let moved = NSPoint(x: down.x - 3, y: down.y)
            let up = try await MouseEventGainBenchmark.timed(window) {
                view.lanes.mouseUp(with: try mouse(.leftMouseUp, moved, in: view))
            }
            try #require(try clip().crossfades.end > start, "\(zoom): the mouse-up made the crossfade longer")
            let reset = try await MouseEventGainBenchmark.timed(window) {
                view.lanes.mouseDown(with: try mouse(.leftMouseDown, moved, in: view, clicks: 2))
                view.lanes.mouseUp(with: try mouse(.leftMouseUp, moved, in: view, clicks: 2))
            }
            try #require(try clip().crossfades.end == .zero, "\(zoom): the double-click removed the crossfade")
            MouseEventGainBenchmark.report("crossfade", zoom, sorted, oneOff: [up, reset])
            p50.append(sorted[60])
        }
        try #require(p50.count == fade.count)
        for (index, (zoom, _)) in MouseEventBenchmark.zooms.enumerated() {
            let allowed = max(fade[index] * 1.1, fade[index] + .milliseconds(1))
            expectWithinBudget(p50[index], allowed, "crossfade p50 \(zoom): \(p50[index]), fade p50 \(fade[index])")
        }
    }
}
