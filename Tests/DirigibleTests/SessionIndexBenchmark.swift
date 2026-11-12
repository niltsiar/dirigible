import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import SwiftUI
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Session-index criterion X13a: on the 2 h fixture plus 200 markers and 50 chapters (12,250
/// rows), one search key is the filter of `SessionIndex` and the update of the list in the pane,
/// timed to the end of the layout. The budget is 16 ms p95 over 60 keys with -O
/// (`make bench FILTER=SessionIndexBenchmark`), 100 ms in debug (a proxy: a miss only prints).
@Suite(.serialized) @MainActor struct SessionIndexBenchmark {
    #if DEBUG
        static let budget = Duration.milliseconds(100)
    #else
        static let budget = Duration.milliseconds(16)
    #endif

    /// The session of `MouseEventBenchmark.fixture` (6 tracks, 2,000 clips each) with 200 markers
    /// and 50 chapters. Every row name starts with "take", so the first four keys match 12,250 rows.
    static func session() throws -> Session { try fixture().0 }

    static func fixture() throws -> (Session, [FileID: PeakState]) {
        let (base, peaks) = try MouseEventBenchmark.fixture()
        var session = base
        for n in 0..<250 {
            try session.setMarker(
                Marker(
                    id: MarkerID("m\(n)"), name: n < 200 ? "take marker \(n)" : "take chapter \(n)",
                    position: Frames(n * 1_300_000), kind: n < 200 ? .marker : .chapter))
        }
        return (session, peaks)
    }

    /// The typed text of 60 keys: type "take1-3", delete it, and go on.
    static let keys: [String] = {
        let word = Array("take1-3")
        let up = (1...word.count).map { String(word[0..<$0]) }
        let down = (0..<word.count - 1).reversed().map { String(word[0..<$0]) }
        let cycle = up + down
        return (0..<60).map { cycle[$0 % cycle.count] }
    }()

    /// The nearest rank p95 of the sorted times.
    static func p95(_ times: [Duration]) -> Duration { times.sorted()[Int(Double(times.count) * 0.95) - 1] }

    static func p50(_ times: [Duration]) -> Duration { times.sorted()[times.count / 2] }

    /// The filter of one search key on the 12,250 rows, apart from the pane. The filter is one part
    /// of a key, so its budget is the budget of a whole key; `aSearchKeyFitsOneFrame` times the sum.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func theFilterOfASearchKeyFitsOneFrame() throws {
        let session = try Self.session()
        let clock = ContinuousClock()
        var built: SessionIndex?
        let build = clock.measure { built = SessionIndex(session: session) }
        let index = try #require(built)
        try #require(index.rows.count == 12_250)
        print("SessionIndexBenchmark row build: \(build)")

        var times: [Duration] = []
        for (n, key) in (Self.keys + Self.keys).enumerated() {
            var rows: [SessionIndex.Row] = []
            let filter = clock.measure { rows = index.rows(kind: nil, search: key) }
            try #require(key != "take" || rows.count == 12_250, "the key \"take\" must match every row")
            // The first 60 keys warm the filter and are not timed.
            if n >= Self.keys.count { times.append(filter) }
        }
        print(
            "SessionIndexBenchmark filter p95: \(Self.p95(times)), p50 \(Self.p50(times)), "
                + "max \(times.max()!)")
        expectWithinBudget(Self.p95(times), Self.budget, "one search key, filter p95 \(Self.p95(times))")
    }

    // MARK: the pane in a real window

    /// A real session window of the fixture with the pane 260 pt wide, 1440 x 900 pt. The save does
    /// not write: a package write of 12,250 rows must not run during the timed events.
    static func openPane(_ app: AppDelegate, folder: URL, shown: Bool) async throws -> (SessionWindow, Studio, NSWindow)
    {
        app.snaps = false
        let (session, peaks) = try fixture()
        let (model, studio, window, _) = try await openLanes(
            app, try await timelinePackage(in: folder, tracks: 1, seconds: 1))
        let url = studio.url
        studio.environment.saveSession = { _, _ in url }
        try studio.edit(ripple: false) { s throws(SessionError) in s = session }
        await until("the peak pass ends") { studio.peakLoad.pass == nil }
        (studio.peakLoad.states, studio.missingMedia) = (peaks, [:])
        window.setContentSize(NSSize(width: 1440, height: 900))
        model.leadingPane.width = IndexWidth(260)
        if shown { model.toggleIndex() }
        try await showsRows(model, shown ? session.tracks.reduce(250) { $0 + $1.clips.count } : nil)
        try #require(window.backingScaleFactor == 2, "this display has scale \(window.backingScaleFactor)")
        return (model, studio, window)
    }

    /// Waits for the list to show `rows` rows, or for the pane to go when `rows` is nil.
    static func showsRows(_ model: SessionWindow, _ rows: Int?) async throws {
        await until("the list shows \(rows.map(String.init) ?? "no") rows") {
            model.window?.contentView?.layoutSubtreeIfNeeded()
            guard let rows else { return !model.leadingPane.shown }
            return (model.leadingPane.table?.dataSource as? IndexTableSource)?.rows.count == rows
        }
        try await Task.sleep(for: .milliseconds(100))
    }

    /// Runs the main run loop in short turns, with no sleep, until `done`: the SwiftUI update of a
    /// change runs inside the timed span. False after 5 s.
    static func spin(_ window: NSWindow, until done: () -> Bool) -> Bool {
        let end = ContinuousClock.now + .seconds(5)
        while !done() {
            guard ContinuousClock.now < end else { return false }
            CATransaction.flush()
            window.contentView?.layoutSubtreeIfNeeded()
            if !done() { RunLoop.main.run(mode: .default, before: Date()) }
        }
        return true
    }

    static var load: Double {
        var loads = [0.0]
        getloadavg(&loads, 1)
        return loads[0]
    }

    /// One search key in the real pane of a real window, from the text change of the field editor
    /// to the end of the layout: the binding, the body, the filter, the table reload, and the cell
    /// views in view. Each key must show the rows that `SessionIndex` gives for it.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aSearchKeyFitsOneFrame() async throws {
        let folder = try TemporaryFolder()
        let app = AppDelegate(recordings: nil)
        let (model, studio, window) = try await Self.openPane(app, folder: folder.url, shown: true)
        let pane = model.leadingPane
        let source = try #require(pane.table?.dataSource as? IndexTableSource)
        let index = SessionIndex(session: studio.session)
        try #require(index.rows.count == 12_250 && source.rows.count == 12_250)
        var expected: [String: [SessionIndex.Row]] = [:]
        for key in Self.keys + [""] { expected[key] = index.rows(kind: nil, search: key) }
        let field = try #require(model.indexSearchField)
        try #require(window.makeFirstResponder(field))
        let editor = try #require(window.fieldEditor(false, for: field) as? NSTextView)
        var times: [Duration] = []
        for (n, key) in (Self.keys + Self.keys).enumerated() {
            try await Task.sleep(for: .microseconds(16_700))
            let (bodies, rows) = (pane.bodies, try #require(expected[key]))
            let start = ContinuousClock.now
            editor.string = key
            editor.didChangeText()
            let done = Self.spin(window) { pane.bodies > bodies && source.rows.count == rows.count }
            let time = ContinuousClock.now - start
            try #require(done, "key \(n) \"\(key)\": the list did not update (search \"\(pane.search)\")")
            try #require(pane.search == key && source.rows == rows, "key \(n) \"\(key)\": wrong rows")
            // The first 60 keys warm the window and are not timed.
            if n >= Self.keys.count { times.append(time) }
        }
        print(
            "SessionIndexBenchmark pane search key: p50 \(Self.p50(times)), p95 \(Self.p95(times)), "
                + "max \(times.max()!), load \(Self.load)")
        expectWithinBudget(Self.p95(times), Self.budget, "one search key in the pane, p95 \(Self.p95(times))")
        window.close()
        await model.close()
    }

    /// The Delete of one clip with the pane hidden and shown, in one run. The command, the
    /// SwiftUI update, the lane render, and with the pane shown the list update, to the end of
    /// `drawNow`. Hidden and shown alternate in blocks of 35 Deletes (5 not timed), 60 timed each,
    /// so a drift of the load shows in both. The budget is the p95 of shown minus the p95 of hidden.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func theIndexAddsUnderOneFrameToADelete() async throws {
        let folder = try TemporaryFolder()
        let app = AppDelegate(recordings: nil)
        let (model, studio, window) = try await Self.openPane(app, folder: folder.url, shown: false)
        let ids = (0..<140).map { studio.session.tracks[$0 % 6].clips[500 + $0 / 6].id }
        var clips = studio.session.tracks.reduce(0) { $0 + $1.clips.count }
        var times: [Bool: [Duration]] = [false: [], true: []]
        var n = 0
        for shown in [false, true, false, true] {
            if model.leadingPane.shown != shown {
                model.toggleIndex()
                try await Self.showsRows(model, shown ? clips + 250 : nil)
            }
            let source = shown ? try #require(model.leadingPane.table?.dataSource as? IndexTableSource) : nil
            for event in 0..<35 {
                model.timeline.selection = .clips(ClipSet(ids[n]))
                try await Task.sleep(for: .microseconds(16_700))
                clips -= 1
                let start = ContinuousClock.now
                model.run(.delete)
                let done = Self.spin(window) {
                    let drawn = model.timelineView?.lanes.inputs?.session.tracks.reduce(0) { $0 + $1.clips.count }
                    return drawn == clips && (!shown || source?.rows.count == clips + 250)
                }
                drawNow(window)
                let time = ContinuousClock.now - start
                try #require(done, "Delete \(n): the lanes or the list did not update, shown \(shown)")
                try #require(
                    studio.session.tracks.reduce(0) { $0 + $1.clips.count } == clips, "Delete \(n) removed no clip")
                if event >= 5 { times[shown, default: []].append(time) }
                n += 1
            }
        }
        let (hidden, shown) = (try #require(times[false]), try #require(times[true]))
        let added = Self.p95(shown) - Self.p95(hidden)
        print(
            "SessionIndexBenchmark pane delete: hidden p50 \(Self.p50(hidden)) p95 \(Self.p95(hidden)), "
                + "shown p50 \(Self.p50(shown)) p95 \(Self.p95(shown)), added p95 \(added), "
                + "added p50 \(Self.p50(shown) - Self.p50(hidden)), load \(Self.load)")
        expectWithinBudget(added, Self.budget, "the pane adds \(added) to a Delete at p95")
        window.close()
        await model.close()
    }
}
