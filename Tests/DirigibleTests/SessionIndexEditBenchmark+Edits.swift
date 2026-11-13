import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

extension SessionIndexEditBenchmark {
    /// One edit of the list as a user makes it. `prepare` runs untimed, then `command` is timed to the
    /// end of the next draw, `finished` says that the lanes and the list show the edit, and `restore`
    /// puts the session back, untimed. With the pane hidden `command` is the session edit that the
    /// list command runs.
    struct ListEdit {
        let name: String
        let prepare: @MainActor (_ shown: Bool, _ event: Int) throws -> Void
        let command: @MainActor (_ shown: Bool) -> Void
        let finished: @MainActor (_ shown: Bool) -> Bool
        var settled: @MainActor (_ shown: Bool) -> Bool = { _ in true }
        let restore: @MainActor (_ shown: Bool) throws -> Bool
    }

    /// The key event of the list route: Command-Return, or Delete, to `window`.
    static func key(_ characters: String, code: UInt16, _ flags: NSEvent.ModifierFlags, in window: NSWindow) -> NSEvent
    {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
            keyCode: code)!
    }

    /// Times `edit` with the pane hidden and shown, in blocks of 12 events (2 not timed), 20 timed each,
    /// hidden and shown alternating. It prints the p50 and p95 of both and the pane cost, asserts the
    /// pane budget for the added cost (with -O: 16 ms p95), and prints the split of each span.
    static func time(_ edit: ListEdit, in setup: (SessionWindow, NSWindow)) async throws {
        let (model, window) = setup
        let times = PartTimes()
        var splits: [Bool: [Split]] = [false: [], true: []]
        var n = 0
        for shown in [false, true, false, true] {
            if model.leadingPane.shown != shown {
                model.toggleIndex()
                try await SessionIndexBenchmark.showsRows(model, shown ? 12_250 : nil)
            }
            for event in 0..<12 {
                try edit.prepare(shown, n)
                drawNow(window)
                try await Task.sleep(for: .microseconds(16_700))
                let (split, done) = await timedEvent(
                    model, window, times, command: { edit.command(shown) }, finished: { edit.finished(shown) },
                    settled: { edit.settled(shown) })
                try #require(done, "\(edit.name) \(n): the lanes or the list did not show the edit, shown \(shown)")
                if event >= 2 { splits[shown, default: []].append(split) }
                try #require(try edit.restore(shown), "\(edit.name) \(n): the session did not come back")
                n += 1
            }
        }
        let (hidden, shown) = (try #require(splits[false]), try #require(splits[true]))
        let (p50, p95) = (SessionIndexBenchmark.p50, SessionIndexBenchmark.p95)
        let (hiddenSpans, shownSpans) = (hidden.map(\.span), shown.map(\.span))
        let added = p95(shownSpans) - p95(hiddenSpans)
        print(
            "SessionIndexEditBenchmark \(edit.name): hidden p50 \(ms(p50(hiddenSpans))) p95 \(ms(p95(hiddenSpans))), "
                + "shown p50 \(ms(p50(shownSpans))) p95 \(ms(p95(shownSpans))), added p95 \(ms(added)), "
                + "added p50 \(ms(p50(shownSpans) - p50(hiddenSpans))), load \(SessionIndexBenchmark.load)")
        expectWithinBudget(added, SessionIndexBenchmark.budget, "the pane adds \(added) to \(edit.name) at p95")
        printSplit("\(edit.name) hidden", hidden)
        printSplit("\(edit.name) shown", shown)
    }

    /// The rename commit, the time edit commit, Add, and the Delete of 1 and of 100 rows, each from the
    /// list command to the end of the next draw on the fixture of `SessionIndexBenchmark` (12,250 rows).
    /// With -O each adds 16 ms p95 or less to the same session edit with the pane hidden (both in one
    /// run). The totals print only: the session edit alone takes more than the key event budget of
    /// `NavigationKeyBenchmark` on this fixture. A debug run prints only.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func eachListEditFitsTheKeyBudget() async throws {
        let folder = try TemporaryFolder()
        let app = AppDelegate(recordings: nil)
        let (model, studio, window) = try await SessionIndexBenchmark.openPane(app, folder: folder.url, shown: false)
        app.key = model
        let setup = (model, window)
        let clips = studio.session.tracks.reduce(0) { $0 + $1.clips.count }
        try #require(clips == 12_000 && studio.session.markers.count == 250)
        let rate = studio.session.sampleRate
        func source() -> IndexTableSource? { model.leadingPane.table?.dataSource as? IndexTableSource }
        func laneSession() -> Session? { model.timelineView?.lanes.inputs?.session }
        func focusList(_ shown: Bool) throws {
            guard shown, let table = model.leadingPane.table else { return }
            try #require(window.makeFirstResponder(table), "the list did not take the focus")
        }
        /// The back of an edit: one Undo, and the list and the lanes show the session again.
        func undone(_ shown: Bool, _ session: Session) throws -> Bool {
            try studio.undo()
            return SessionIndexBenchmark.spin(window) {
                laneSession() == session && (!shown || source()?.rows.count == 12_250)
            }
        }
        let start = studio.session
        let marker = MarkerID("m3")
        let name = try #require(start.markers[marker]).name
        let position = try #require(start.markers[marker]).position
        let (returnKey, deleteKey) = (
            Self.key("\r", code: 36, .command, in: window), Self.key("\u{7f}", code: 51, [], in: window)
        )

        try await Self.time(
            ListEdit(
                name: "rename commit",
                prepare: { shown, event in
                    model.beginRowEdit(marker)
                    model.leadingPane.rowEdit?.text = "renamed \(event)"
                    if shown { try #require(source()?.editing?.currentEditor() != nil, "no name field") }
                },
                command: { shown in
                    if shown, let source = source(), let field = source.editing,
                        let editor = field.currentEditor() as? NSTextView
                    {
                        _ = source.control(
                            field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
                    } else {
                        model.finishRowEdit(save: true, strict: true)
                    }
                },
                finished: { shown in
                    let now = studio.session.markers[marker]?.name
                    return now?.hasPrefix("renamed") == true && laneSession() == studio.session
                        && (!shown || source()?.rows.first { $0.id == .marker(marker) }?.name == now)
                },
                restore: { shown in
                    try undone(shown, start) && studio.session.markers[marker]?.name == name
                }),
            in: setup)

        try await Self.time(
            ListEdit(
                name: "time edit commit",
                prepare: { shown, event in
                    model.beginRowEdit(marker, field: .start)
                    let moved = position + Frames(event % 2 == 0 ? 96_000 : 144_000)
                    model.leadingPane.rowEdit?.text = timeDisplayText(moved, rate: rate, playing: false)
                    if shown { try #require(source()?.editing?.currentEditor() != nil, "no time field") }
                },
                command: { shown in
                    if shown, let source = source(), let field = source.editing,
                        let editor = field.currentEditor() as? NSTextView
                    {
                        _ = source.control(
                            field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
                    } else {
                        model.finishRowEdit(save: true, strict: true)
                    }
                },
                finished: { shown in
                    let now = studio.session.markers[marker]?.position
                    return now != position && laneSession() == studio.session
                        && (!shown || source()?.rows.first { $0.id == .marker(marker) }?.position == now)
                },
                restore: { shown in
                    try undone(shown, start) && studio.session.markers[marker]?.position == position
                }),
            in: setup)

        try await Self.time(
            ListEdit(
                name: "add",
                prepare: { shown, _ in try focusList(shown) },
                command: { shown in
                    if shown { app.timeline(.addMarker, event: returnKey, in: window) } else { model.run(.addMarker) }
                },
                finished: { shown in
                    studio.session.markers.count == 251 && laneSession() == studio.session
                        && (!shown || source()?.rows.count == 12_251 && source()?.editing != nil)
                },
                restore: { shown in
                    model.finishRowEdit(save: false)
                    return try undone(shown, start)
                }),
            in: setup)

        for count in [1, 100] {
            let ids = (0..<count).map { start.tracks[$0 % 6].clips[500 + $0 / 6].id }
            let picks = Set(ids.map { SessionIndex.Pick.clip($0) })
            try await Self.time(
                ListEdit(
                    name: "delete of \(count) \(count == 1 ? "row" : "rows")",
                    prepare: { shown, _ in
                        guard shown else { return }
                        try focusList(true)
                        model.timeline.selectRows(picks, anchor: picks.first, form: .indexSet)
                        try #require(model.timeline.selectedRows == picks, "the \(count) rows are not selected")
                    },
                    command: { shown in
                        if shown {
                            app.timeline(.delete, event: deleteKey, in: window)
                        } else {
                            model.removeIndexRows(picks)
                        }
                    },
                    finished: { shown in
                        let drawn = laneSession()?.tracks.reduce(0) { $0 + $1.clips.count }
                        return drawn == clips - count && (!shown || source()?.rows.count == 12_250 - count)
                    },
                    settled: { _ in model.timeline.selectedRows.isDisjoint(with: picks) },
                    restore: { shown in
                        model.timeline.pruneRows(keeping: [])
                        return try undone(shown, start)
                    }),
                in: setup)
        }
        window.close()
        await model.close()
    }
}
