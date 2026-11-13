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
    /// The times of one timed event: the span, the phases and the pane parts by name (`spin/show`),
    /// and the counts of pushes, `reloadData` calls, and index builds in the span.
    struct Split {
        let span: Duration
        let parts: [String: Duration]
        let pushes: Int
        let reloads: Int
        let builds: Int
    }

    /// Times the phases of one span (`enter`) and the parts that the pane marks through
    /// `LeadingPaneState.partMark`. A part adds to the name `<phase>/<part>`; a phase adds to its own
    /// name. Parts nest, so only the parts of `top` add up to the time of their phase.
    final class PartTimes {
        private var open: [(name: String, start: ContinuousClock.Instant)] = []
        private var phase: (name: String, start: ContinuousClock.Instant)?
        private(set) var parts: [String: Duration] = [:]
        static var now: ContinuousClock.Instant { ContinuousClock.now }

        func reset() { (open, phase, parts) = ([], nil, [:]) }

        func enter(_ next: String?) {
            if let phase { parts[phase.name, default: .zero] += Self.now - phase.start }
            phase = next.map { ($0, Self.now) }
        }

        func mark(_ name: String, _ begins: Bool) {
            if begins {
                open.append((name, Self.now))
            } else if let part = open.popLast(), let phase {
                parts["\(phase.name)/\(part.name)", default: .zero] += Self.now - part.start
            }
        }
    }

    static let addedBudget = Duration.milliseconds(40)
    static let shownBudget = Duration.milliseconds(100)

    /// The parts that no other part of the list holds. The table `show` holds its `show` lines, and
    /// the drop holds the prune and the push. A part in the command phase is in the command time.
    static let top = ["index compare", "index update", "rows filter", "show", "table layout", "drop gone rows"]

    /// The timed span of each event: the command, the run loop until `finished` (the SwiftUI update,
    /// the list update, and the layout) and until `settled` (a main-actor task of the window, such as
    /// the drop of gone rows, has run), and the draw. It is a function of its own, so a trace keeps
    /// only its samples (`scripts/bench.sh --trace <file> --under timedSpan`).
    @inline(never)
    static func timedSpan(
        _ command: @MainActor () -> Void, _ finished: @MainActor () -> Bool, _ settled: @MainActor () -> Bool,
        _ window: NSWindow, _ times: PartTimes
    ) async -> Bool {
        times.enter("command")
        command()
        times.enter("spin")
        var done = SessionIndexBenchmark.spin(window, until: finished)
        let end = PartTimes.now + .seconds(5)
        while done && !settled() {
            guard PartTimes.now < end else {
                done = false
                break
            }
            await Task.yield()
        }
        times.enter("draw")
        drawNow(window)
        times.enter(nil)
        return done
    }

    /// One event, timed to the end of `drawNow`, with the pane parts marked.
    static func timedEvent(
        _ model: SessionWindow, _ window: NSWindow, _ times: PartTimes,
        command: @MainActor () -> Void, finished: @MainActor () -> Bool, settled: @MainActor () -> Bool = { true }
    ) async -> (split: Split, done: Bool) {
        let pane = model.leadingPane
        times.reset()
        pane.partMark = { times.mark($0, $1) }
        defer { pane.partMark = nil }
        let (pushes, reloads, builds) = (pane.pushes, pane.table?.reloads ?? 0, pane.builds)
        let start = ContinuousClock.now
        let done = await timedSpan(command, finished, settled, window, times)
        let span = ContinuousClock.now - start
        let split = Split(
            span: span, parts: times.parts, pushes: pane.pushes - pushes,
            reloads: (pane.table?.reloads ?? 0) - reloads, builds: pane.builds - builds)
        return (split, done)
    }

    static func ms(_ time: Duration) -> String {
        let (seconds, atto) = time.components
        return String(format: "%.1f ms", Double(seconds) * 1e3 + Double(atto) * 1e-15)
    }

    /// Prints one line for each part: p50 and p95 over the events (a part that an event lacks counts
    /// 0), then the sum of the named parts against the span. The named parts are the command and the
    /// `top` parts of the spin and the draw. The lane render may end in the spin or in the draw, so
    /// the remainder joins both: it is the lane render, the rest of the SwiftUI body, the run loop,
    /// and the glue of the span. Read the remainder of the shown span against the hidden one.
    static func printSplit(_ title: String, _ events: [Split]) {
        let (p50, p95) = (SessionIndexBenchmark.p50, SessionIndexBenchmark.p95)
        func line(_ name: String, _ times: [Duration]) {
            print("SessionIndexEditBenchmark split \(title) \(name): p50 \(ms(p50(times))), p95 \(ms(p95(times)))")
        }
        func part(_ event: Split, _ name: String) -> Duration { event.parts[name] ?? .zero }
        func tops(_ event: Split) -> Duration {
            ["spin", "draw"].reduce(.zero) { sum, phase in top.reduce(sum) { $0 + part(event, "\(phase)/\($1)") } }
        }
        let phases = ["command", "spin", "draw"]
        line("span", events.map(\.span))
        for name in phases + Set(events.flatMap { $0.parts.keys }).subtracting(phases).sorted() {
            line(name, events.map { part($0, name) })
        }
        let sum = events.map { part($0, "command") + tops($0) }
        line("sum of command and top parts", sum)
        line("remainder of the span", zip(events, sum).map { $0.span - $1 })
        for (name, count) in [("pushes", \Split.pushes), ("reloadData calls", \.reloads), ("index builds", \.builds)] {
            let all = events.map { $0[keyPath: count] }.sorted()
            print("SessionIndexEditBenchmark split \(title) \(name): p50 \(all[all.count / 2]), max \(all.last ?? 0)")
        }
    }

    /// The Delete of all 12,000 clips by the lanes: Select All, then Delete. The command, the
    /// SwiftUI update, the lane render, and with the pane shown the list update are timed; the
    /// Select All and the Undo that puts the clips back are not. Hidden and shown alternate in
    /// blocks of 12 Deletes (2 not timed), 20 timed each. With -O the pane adds 40 ms p95 or less and
    /// the shown span is 100 ms p95 or less. The change of 12,000 rows is over the row limit of the
    /// table, so it reloads the table; the trace floor of that is about 21 ms, over one frame. It also
    /// prints the split of each span by part, and the split of the removal of all 12,250 rows in one
    /// edit with a list selection of all of them (the drop of the gone rows and its push), which
    /// asserts nothing.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func theLaneDeleteOfAllClipsAddsUnderItsBudget() async throws {
        let folder = try TemporaryFolder()
        let app = AppDelegate(recordings: nil)
        let (model, studio, window) = try await SessionIndexBenchmark.openPane(app, folder: folder.url, shown: false)
        let clips = studio.session.tracks.reduce(0) { $0 + $1.clips.count }
        let marks = studio.session.markers.count
        try #require(clips == 12_000 && marks == 250)
        func drawn() -> Int? { model.timelineView?.lanes.inputs?.session.tracks.reduce(0) { $0 + $1.clips.count } }
        let times = PartTimes()
        var splits: [Bool: [Split]] = [false: [], true: []]
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
                let (split, done) = await Self.timedEvent(
                    model, window, times, command: { model.run(.delete) },
                    finished: { drawn() == 0 && (!shown || source?.rows.count == marks) })
                try #require(done, "Delete \(n): the lanes or the list did not update, shown \(shown)")
                try #require(studio.session.tracks.allSatisfy { $0.clips.isEmpty }, "Delete \(n) left a clip")
                try #require(studio.session.markers.count == marks, "Delete \(n) removed a marker")
                if event >= 2 { splits[shown, default: []].append(split) }
                try studio.undo()
                let back = SessionIndexBenchmark.spin(window) {
                    drawn() == clips && (!shown || source?.rows.count == clips + marks)
                }
                try #require(back, "Undo \(n): the lanes or the list did not show the clips again")
                n += 1
            }
        }
        let (hidden, shown) = (try #require(splits[false]), try #require(splits[true]))
        let (p50, p95) = (SessionIndexBenchmark.p50, SessionIndexBenchmark.p95)
        let (hiddenSpans, shownSpans) = (hidden.map(\.span), shown.map(\.span))
        let added = p95(shownSpans) - p95(hiddenSpans)
        print(
            "SessionIndexEditBenchmark lane delete of all clips: hidden p50 \(p50(hiddenSpans)) p95 \(p95(hiddenSpans)), "
                + "shown p50 \(p50(shownSpans)) p95 \(p95(shownSpans)), added p95 \(added), "
                + "added p50 \(p50(shownSpans) - p50(hiddenSpans)), load \(SessionIndexBenchmark.load)")
        expectWithinBudget(added, Self.addedBudget, "the pane adds \(added) to a lane Delete of all clips at p95")
        let shownP95 = p95(shownSpans)
        expectWithinBudget(shownP95, Self.shownBudget, "a lane Delete of all clips shows in \(shownP95) at p95")
        Self.printSplit("lane delete hidden", hidden)
        Self.printSplit("lane delete shown", shown)

        // The edit writes no lane selection, so the window drops the 12,250 gone rows and pushes once.
        let source = try #require(model.leadingPane.table?.dataSource as? IndexTableSource)
        let ids = studio.session.tracks.flatMap { $0.clips.map(\.id) }
        let markers = Array(studio.session.markers.keys)
        let picks = Set(ids.map { SessionIndex.Pick.clip($0) } + markers.map { .marker($0) })
        var listed: [Split] = []
        var failure: String?
        for event in 0..<24 {
            model.timeline.selectRows(picks, anchor: ids.first.map { .clip($0) })
            try #require(model.timeline.selectedRows.count == picks.count, "List Delete \(event): rows not selected")
            drawNow(window)
            try await Task.sleep(for: .microseconds(16_700))
            let (split, done) = await Self.timedEvent(
                model, window, times,
                command: {
                    do {
                        try studio.edit(ripple: false) { session throws(SessionError) in
                            try session.removeClips(ids)
                            for id in markers { try session.removeMarker(id) }
                        }
                    } catch { failure = "\(error)" }
                },
                finished: { source.rows.isEmpty && drawn() == 0 },
                settled: { model.timeline.selectedRows.isEmpty })
            let state =
                "list \(source.rows.count), lanes \(drawn() ?? -1), selected \(model.timeline.selectedRows.count)"
            try #require(done, "List Delete \(event): edit \(failure ?? "ok"), \(state)")
            if event % 12 >= 2 { listed.append(split) }
            try studio.undo()
            let back = SessionIndexBenchmark.spin(window) { drawn() == clips && source.rows.count == clips + marks }
            try #require(back, "List Undo \(event): the lanes or the list did not show the rows again")
        }
        Self.printSplit("list delete of all rows shown", listed)
        window.close()
        await model.close()
    }

    /// The edit of a list Delete of all rows: `removeClips` of 12,000 IDs and 250 marker removals in
    /// one edit. It is the base of `deleteOfAllRowsAddsUnderOneFrame`: the pane is hidden, so the
    /// span holds the edit, the lane render, and the draw, and no list work. Prints only; the hidden
    /// p95 sets the added limit of the list Delete (the lower of 16 ms and 50 ms minus this p95).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func theListDeleteEditGivesItsPaneHiddenBase() async throws {
        let folder = try TemporaryFolder()
        let app = AppDelegate(recordings: nil)
        let (model, studio, window) = try await SessionIndexBenchmark.openPane(app, folder: folder.url, shown: false)
        let clips = studio.session.tracks.reduce(0) { $0 + $1.clips.count }
        let ids = studio.session.tracks.flatMap { $0.clips.map(\.id) }
        let markers = Array(studio.session.markers.keys)
        try #require(ids.count == 12_000 && markers.count == 250 && clips == ids.count)
        func drawn() -> Int? { model.timelineView?.lanes.inputs?.session.tracks.reduce(0) { $0 + $1.clips.count } }
        let times = PartTimes()
        var spans: [Split] = []
        var failure: String?
        for event in 0..<22 {
            drawNow(window)
            try await Task.sleep(for: .microseconds(16_700))
            let (split, done) = await Self.timedEvent(
                model, window, times,
                command: {
                    do {
                        try studio.edit(ripple: false) { session throws(SessionError) in
                            try session.removeClips(ids)
                            for id in markers { try session.removeMarker(id) }
                        }
                    } catch { failure = "\(error)" }
                },
                finished: { drawn() == 0 })
            try #require(done, "Hidden list Delete \(event): edit \(failure ?? "ok"), lanes \(drawn() ?? -1)")
            try #require(studio.session.markers.isEmpty, "Hidden list Delete \(event) left a marker")
            if event >= 2 { spans.append(split) }
            try studio.undo()
            let back = SessionIndexBenchmark.spin(window) { drawn() == clips }
            try #require(back, "Hidden list Undo \(event): the lanes did not show the clips again")
        }
        let hidden = spans.map(\.span)
        let (p50, p95) = (SessionIndexBenchmark.p50, SessionIndexBenchmark.p95)
        print(
            "SessionIndexEditBenchmark list delete edit pane hidden: p50 \(Self.ms(p50(hidden))), "
                + "p95 \(Self.ms(p95(hidden))), load \(SessionIndexBenchmark.load)")
        window.close()
        await model.close()
    }
}
