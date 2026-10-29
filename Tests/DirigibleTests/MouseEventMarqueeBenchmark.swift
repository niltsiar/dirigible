import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Marquee-select C12 (decision 0038): one marquee drag event on the 2 h fixture of
/// `MouseEventBenchmark` fits one 60 Hz frame, p95 16 ms or less with -O at 2880 x 1200 px (`make
/// bench FILTER=MouseEventMarqueeBenchmark`). The event is the gesture step, the selection effect,
/// the SwiftUI update that carries the new clip set, and the draw of the changed columns. A Shift
/// press is a range press in each zone, and the contiguous fixture clips leave no gap, so the press
/// needs no setup. The clips are 172,800 frames long, so a clip ends at every multiple of 172,800.
/// The wide path presses at the session start and walks around the session end at fit zoom, so
/// the held set has about 12,000 clips (2,000 on each of 6 lanes) at each event.
@MainActor struct MouseEventMarqueeBenchmark {
    static let clipLength = 172_800.0

    /// Each event of a path ends the pointer at `x(event)` in the lane of `y`. The press is at x 330 pt
    /// in lane 1 unless the path says `down`.
    struct Path {
        let name: String
        let y: Double
        let changesTheSet: Bool
        var down = NSPoint(x: 330, y: 80)
        /// The pointer walks around the session end; fit zoom only, because the end is off screen at
        /// the zoom of 60 pt boxes.
        var wide = false
    }

    static let paths = [
        Path(name: "2 lanes, the held set changes", y: 180, changesTheSet: true),
        Path(name: "6 lanes, the held set changes", y: 580, changesTheSet: true),
        Path(name: "6 lanes, the held set stays", y: 580, changesTheSet: false),
        Path(name: "6 lanes, the whole session", y: 580, changesTheSet: true, down: NSPoint(x: 0, y: 80), wide: true),
    ]

    /// The pointer x of an event. A changing walk alternates between 421 and 419 pt, 1 pt each side
    /// of the clip end at 420 pt (60 pt boxes); at fit zoom 2 pt are about 2.8 clips. A steady walk
    /// alternates between two points inside the clip that ends after x 421 pt: no clip end lies
    /// between them.
    static func x(_ event: Int, _ path: Path, framesPerPoint: Double) -> Double {
        // The wide walk alternates between 1440 and 1439 pt: the last clip ends at 1440 pt.
        if path.wide { return event % 2 == 1 ? 1440 : 1439 }
        if path.changesTheSet { return event % 2 == 1 ? 421 : 419 }
        let end = (421 * framesPerPoint / clipLength).rounded(.down) * clipLength
        return (end + (event % 2 == 1 ? 20_000 : 100_000)) / framesPerPoint
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aMarqueeDragEventFitsOneFrameAtTwoHours() async throws {
        let folder = try TemporaryFolder()
        let app = AppDelegate(recordings: nil)
        let (session, peaks) = try MouseEventBenchmark.fixture()
        var n = 0
        for path in Self.paths {
            for (zoom, framesPerPoint) in MouseEventBenchmark.zooms where !path.wide || zoom == "fit" {
                n += 1
                let package = folder.url.appending(path: "\(n)")
                try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
                let (window, view, model, inputs) = try await MouseEventBenchmark.lanesAndInputs(
                    session, peaks, framesPerPoint: framesPerPoint, app: app, folder: package)
                try #require(window.backingScaleFactor == 2, "this display has scale \(window.backingScaleFactor)")
                let label = "\(path.name), \(zoom)"
                view.lanes.mouseDown(with: try mouse(.leftMouseDown, path.down, in: view, flags: .shift))
                var selections: [Selection] = []
                let event: (Int) throws -> NSEvent = { index in
                    selections.append(model.timeline.selection)
                    return try mouse(
                        .leftMouseDragged, NSPoint(x: Self.x(index, path, framesPerPoint: framesPerPoint), y: path.y),
                        in: view, flags: .shift)
                }
                let sorted =
                    path.changesTheSet
                    ? try await MouseEventBenchmark.pacedDrags(view, window, label, swiftUI: (model, inputs), event)
                    : try await Self.steadyDrags(view, window, model, inputs, event)
                selections.append(model.timeline.selection)
                view.lanes.mouseUp(with: try mouse(.leftMouseUp, path.down, in: view, flags: .shift))
                if path.wide {
                    let counts = selections.dropFirst().map { selection -> Int in
                        if case .clips(let set) = selection { return set.ids.count }
                        return 0
                    }
                    #expect(counts.min() ?? 0 >= 11_900, "\(label): the marquee holds \(counts.min() ?? 0) clips")
                }
                if path.changesTheSet {
                    #expect(
                        zip(selections, selections.dropFirst()).allSatisfy { $0 != $1 },
                        "\(label): an event kept the clip set")
                } else {
                    let held = selections.dropFirst()
                    #expect(held.first != Selection.none, "\(label): the marquee holds clips")
                    #expect(held.allSatisfy { $0 == held.first }, "\(label): the clip set changed")
                }
                print("MouseEventMarqueeBenchmark \(label): p50 \(sorted[60]), p95 \(sorted[113])")
                expectWithinBudget(sorted[113], MouseEventBenchmark.budget, "\(label): p95 \(sorted[113])")
                window.close()
                await model.close()
            }
        }
    }

    /// `MouseEventBenchmark.pacedDrags` for events that change no drawn input: the live event, 59 of
    /// 60 at the zoom of 60 pt boxes. The event, the SwiftUI update, and the draw are timed; no draw
    /// is required.
    static func steadyDrags(
        _ view: TimelineScrollView, _ window: NSWindow, _ model: SessionWindow, _ inputs: LaneInputs,
        _ event: (Int) throws -> NSEvent
    ) async throws -> [Duration] {
        var times: [Duration] = []
        for n in 1...130 {
            let drag = try event(n)
            try await Task.sleep(for: .microseconds(16_700))
            let start = ContinuousClock.now
            view.lanes.mouseDragged(with: drag)
            MouseEventBenchmark.swiftUIUpdate(view, model, inputs)
            drawNow(window)
            if n > 10 { times.append(ContinuousClock.now - start) }
        }
        return times.sorted()
    }
}
