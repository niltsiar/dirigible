import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Edit times of the session index on the fixture of `SessionIndexBenchmark` (12,250 rows): each
/// edit with the pane hidden and shown, in one run, timed to the end of `drawNow`
/// (`make bench FILTER=SessionIndexEditBenchmark`; a debug run prints only).
@Suite(.serialized) @MainActor struct SessionIndexEditBenchmark {
    /// The Delete of all 12,000 clips by the lanes: Select All, then Delete. The command, the
    /// SwiftUI update, the lane render, and with the pane shown the list update are timed; the
    /// Select All and the Undo that puts the clips back are not. Hidden and shown alternate in
    /// blocks of 12 Deletes (2 not timed), 20 timed each. It prints the times and asserts no budget:
    /// they are the base that a Delete of all rows from the list is compared with.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func theLaneDeleteOfAllClipsGivesTheBase() async throws {
        let folder = try TemporaryFolder()
        let app = AppDelegate(recordings: nil)
        let (model, studio, window) = try await SessionIndexBenchmark.openPane(app, folder: folder.url, shown: false)
        let clips = studio.session.tracks.reduce(0) { $0 + $1.clips.count }
        let marks = studio.session.markers.count
        try #require(clips == 12_000 && marks == 250)
        func drawn() -> Int? { model.timelineView?.lanes.inputs?.session.tracks.reduce(0) { $0 + $1.clips.count } }
        var times: [Bool: [Duration]] = [false: [], true: []]
        var n = 0
        for shown in [false, true, false, true] {
            if model.leadingPane.shown != shown {
                model.toggleIndex()
                try await SessionIndexBenchmark.showsRows(model, shown ? clips + marks : nil)
            }
            let source = shown ? try #require(model.leadingPane.table?.dataSource as? IndexTableSource) : nil
            for event in 0..<12 {
                model.run(.selectAll)
                try await Task.sleep(for: .microseconds(16_700))
                let start = ContinuousClock.now
                model.run(.delete)
                let done = SessionIndexBenchmark.spin(window) {
                    drawn() == 0 && (!shown || source?.rows.count == marks)
                }
                drawNow(window)
                let time = ContinuousClock.now - start
                try #require(done, "Delete \(n): the lanes or the list did not update, shown \(shown)")
                try #require(studio.session.tracks.allSatisfy { $0.clips.isEmpty }, "Delete \(n) left a clip")
                try #require(studio.session.markers.count == marks, "Delete \(n) removed a marker")
                if event >= 2 { times[shown, default: []].append(time) }
                try studio.undo()
                let back = SessionIndexBenchmark.spin(window) {
                    drawn() == clips && (!shown || source?.rows.count == clips + marks)
                }
                try #require(back, "Undo \(n): the lanes or the list did not show the clips again")
                n += 1
            }
        }
        let (hidden, shown) = (try #require(times[false]), try #require(times[true]))
        let (p50, p95) = (SessionIndexBenchmark.p50, SessionIndexBenchmark.p95)
        print(
            "SessionIndexEditBenchmark lane delete of all clips: hidden p50 \(p50(hidden)) p95 \(p95(hidden)), "
                + "shown p50 \(p50(shown)) p95 \(p95(shown)), added p95 \(p95(shown) - p95(hidden)), "
                + "added p50 \(p50(shown) - p50(hidden)), load \(SessionIndexBenchmark.load)")
        window.close()
        await model.close()
    }
}
