import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Multi-clip-selection C16 (decision 0038): one group drag event on the 2 h fixture of
/// `MouseEventBenchmark` fits one 60 Hz frame, p95 16 ms or less with -O at 2880 x 1200 px (`make
/// bench FILTER=MouseEventGroupBenchmark`). The event is the gesture step, the preview `nudge` with
/// lanes on a copy of the session, and the draw of the changed columns. Each path runs at a fit zoom
/// that is not a whole number of frames per point and at the zoom of 60 pt boxes. The selected
/// clips are 20 pt at fit zoom (60 pt at the other zoom) and start at x 300 pt: a fixture clip is
/// 0.72 pt at fit zoom, all range zone.
@MainActor struct MouseEventGroupBenchmark {
    static let zooms = [
        ("fit", Double(MouseEventBenchmark.frames) / 1439.3),
        ("60 pt boxes", Double(MouseEventBenchmark.frames / 2000) / 60),
    ]

    /// A path: the lanes of the selected clips, the frames from the first clip to each clip, and
    /// the lanes that each event moves (0 or 1, every second event).
    struct Path {
        let name: String
        let lanes: [Int]
        let later: [Frames]
        let laneMove: Bool
    }

    static let hour = Frames(172_800_000)
    static let paths = [
        Path(name: "2 clips in time", lanes: [1, 2], later: [.zero, .zero], laneMove: false),
        Path(name: "2 clips one lane down", lanes: [1, 2], later: [.zero, .zero], laneMove: true),
        Path(name: "6 clips in time", lanes: Array(0..<6), later: Array(repeating: .zero, count: 6), laneMove: false),
        Path(name: "2 clips 1 h apart", lanes: [1, 2], later: [.zero, hour], laneMove: false),
    ]

    /// The session with a selected clip "g<n>" on each lane of `path`, and the clip set.
    static func session(_ fixture: Session, _ path: Path, framesPerPoint: Double) throws -> (Session, Selection) {
        var session = fixture
        let start = Frames(Int(framesPerPoint * 300))
        let length = Frames(Int(framesPerPoint * (framesPerPoint > 10_000 ? 20 : 60)))
        var ids: Set<ClipID> = []
        for (n, (lane, later)) in zip(path.lanes, path.later).enumerated() {
            let id = ClipID("g\(n)")
            let file = session.tracks[lane].clips[0].file
            try session.place(
                Clip(id: id, file: file, start: start + later, offset: start + later, length: length),
                on: session.tracks[lane].id)
            ids.insert(id)
        }
        return (session, .clips(try #require(ClipSet(ids))))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aGroupDragEventFitsOneFrameAtTwoHours() async throws {
        let folder = try TemporaryFolder()
        let app = AppDelegate(recordings: nil)
        let (fixture, peaks) = try MouseEventBenchmark.fixture()
        var n = 0
        for path in Self.paths {
            for (zoom, framesPerPoint) in Self.zooms {
                n += 1
                let (session, selection) = try Self.session(fixture, path, framesPerPoint: framesPerPoint)
                let label = "\(path.name), \(zoom)"
                let sorted = try await Self.drags(
                    session, peaks, selection, framesPerPoint: framesPerPoint, laneMove: path.laneMove,
                    app: app, folder: folder.url.appending(path: "\(n)"), label: label)
                print("MouseEventGroupBenchmark \(label): p50 \(sorted[60]), p95 \(sorted[113])")
                expectWithinBudget(sorted[113], MouseEventBenchmark.budget, "\(label): p95 \(sorted[113])")
            }
        }
        // U14: a drag after Select All (12,000 clips) is outside the budget; it only prints.
        let (session, _) = try Self.session(fixture, Self.paths[0], framesPerPoint: Self.zooms[0].1)
        let sorted = try await Self.drags(
            session, peaks, .range(Marks.all(in: session)), framesPerPoint: Self.zooms[0].1, laneMove: false,
            app: app, folder: folder.url.appending(path: "all"), label: "Select All, fit")
        print("MouseEventGroupBenchmark Select All, fit (no budget): p50 \(sorted[60]), p95 \(sorted[113])")
    }

    /// 130 paced drags of "g0" with `selection`, each 1 pt right of the last (and one lane down
    /// every second event with `laneMove`). After the clock stops, each event must have moved g0.
    static func drags(
        _ session: Session, _ peaks: [FileID: PeakState], _ selection: Selection, framesPerPoint: Double,
        laneMove: Bool, app: AppDelegate, folder: URL, label: String
    ) async throws -> [Duration] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var (window, view, model, inputs) = try await MouseEventBenchmark.lanesAndInputs(
            session, peaks, framesPerPoint: framesPerPoint, app: app, folder: folder)
        try #require(window.backingScaleFactor == 2, "this display has scale \(window.backingScaleFactor)")
        model.timeline.selection = selection
        inputs.selection = selection
        view.update(inputs)
        drawNow(window)
        let box = try #require(view.lanes.clipFrame("g0"))
        try #require(box.width >= 12 && box.minX < 1300, "\(label): \(box)")
        let down = NSPoint(x: box.minX + 10, y: box.minY + 10)
        view.lanes.mouseDown(with: try mouse(.leftMouseDown, down, in: view))
        var starts: [Frames?] = []
        let sorted = try await MouseEventBenchmark.pacedDrags(view, window, label) { event in
            starts.append(view.lanes.inputs?.session.clip("g0")?.clip.start)
            let y = down.y + (laneMove && event % 2 == 1 ? 100 : 0)
            return try mouse(.leftMouseDragged, NSPoint(x: down.x + Double(3 + event), y: y), in: view)
        }
        starts.append(view.lanes.inputs?.session.clip("g0")?.clip.start)
        view.lanes.mouseUp(with: try mouse(.leftMouseUp, down, in: view))
        let moved = zip(starts, starts.dropFirst()).allSatisfy { $0 != $1 }
        #expect(moved, "\(label): an event did not move g0")
        window.close()
        await model.close()
        return sorted
    }
}
