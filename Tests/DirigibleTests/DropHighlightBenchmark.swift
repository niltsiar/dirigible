import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp

/// Run 13c C11: one drag update of a Finder drop on the 2 h fixture fits one 60 Hz frame, p95
/// 16 ms or less over 120 updates with -O (`make bench FILTER=DropHighlightBenchmark`), at
/// 2880 x 1200 px. The fast test `theCueFollowsThePointerWithNoLaneDraw` holds the draw-count
/// assert (C9 d).
extension MouseEventBenchmark {
    /// The paths of a drag: the files and the lane point of update n. The 6 lanes of 100 pt fill
    /// the view, so the New Track zone is the last 32 pt of the lanes in view.
    static let dropPaths: [(name: String, files: Int, point: (Int) -> NSPoint)] = [
        ("one file across lanes", 1, { NSPoint(x: 300 + Double($0), y: $0 % 2 == 0 ? 150 : 250) }),
        ("one file in the New Track zone", 1, { NSPoint(x: 300 + Double($0), y: 590) }),
        ("two files over a lane", 2, { NSPoint(x: 300 + Double($0), y: 150) }),
    ]

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aDropUpdateFitsOneFrameAtTwoHours() async throws {
        let folder = try TemporaryFolder()
        let app = AppDelegate(recordings: nil)
        let (session, peaks) = try Self.fixture()
        let files = try ["A.wav", "B.wav"].map { name in
            let url = folder.url.appending(path: name)
            try writeSilentWAV(url, channels: 1)
            return url
        }
        for (n, (zoom, framesPerPoint)) in Self.zooms.enumerated() {
            let package = folder.url.appending(path: "\(n)")
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            let (window, view, model) = try await Self.lanesOnScreen(
                session, peaks, framesPerPoint: framesPerPoint, app: app, folder: package)
            try #require(window.backingScaleFactor == 2, "this display has scale \(window.backingScaleFactor)")
            try #require(view.shown.width == 1440 && view.shown.height >= 600, "\(view.shown)")
            for path in Self.dropPaths {
                let enter = fileDrag(Array(files.prefix(path.files)), at: path.point(0), in: view)
                try #require(view.draggingEntered(enter) == .copy, "\(zoom), \(path.name): the drag enters")
                var times: [Duration] = []
                for update in 1...130 {
                    let drag = FakeDrag(dropBoard, at: view.lanes.convert(path.point(update), to: nil))
                    let (line, draws) = (view.lanes.drop.line.frame, view.lanes.draws)
                    try await Task.sleep(for: .microseconds(16_700))
                    let start = ContinuousClock.now
                    let operation = view.draggingUpdated(drag)
                    drawNow(window)
                    // The first 10 updates are not timed (the draw after the window shows).
                    if update > 10 { times.append(ContinuousClock.now - start) }
                    let moved = view.lanes.drop.line.frame != line
                    try #require(operation == .copy && moved, "\(zoom), \(path.name): update \(update) moved no line")
                    try #require(view.lanes.draws == draws, "\(zoom), \(path.name): update \(update) drew the lanes")
                }
                view.draggingExited(enter)
                let sorted = times.sorted()
                print("DropHighlightBenchmark \(zoom), \(path.name): p50 \(sorted[60]), p95 \(sorted[113])")
                expectWithinBudget(sorted[113], Self.budget, "\(zoom), \(path.name): p95 \(sorted[113])")
            }
            window.close()
            await model.close()
        }
    }
}
