import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import SwiftUI
import Testing

@testable import DirigibleApp

/// Session-index criterion X13a, the parts of the model (run 2026-10-28-session-index-zoom, L1-S1,
/// unknown U2): on the 2 h fixture plus 200 markers and 50 chapters (12,250 rows), one search key
/// is the filter of `SessionIndex` and the update of an `NSTableView` in a window 260 pt wide,
/// timed to the end of the draw. The budget is 16 ms p95 over 60 keys with -O
/// (`make bench FILTER=SessionIndexBenchmark`), 100 ms in debug (a proxy: a miss only prints).
@MainActor struct SessionIndexBenchmark {
    #if DEBUG
        static let budget = Duration.milliseconds(100)
    #else
        static let budget = Duration.milliseconds(16)
    #endif

    /// The session of `MouseEventBenchmark.fixture` (6 tracks, 2,000 clips each) with 200 markers
    /// and 50 chapters. Every row name starts with "take", so the first four keys match 12,250 rows.
    static func session() throws -> Session {
        var (session, _) = try MouseEventBenchmark.fixture()
        for n in 0..<250 {
            try session.setMarker(
                Marker(
                    id: MarkerID("m\(n)"), name: n < 200 ? "take marker \(n)" : "take chapter \(n)",
                    position: Frames(n * 1_300_000), kind: n < 200 ? .marker : .chapter))
        }
        return session
    }

    /// The typed text of 60 keys: type "take1-3", delete it, and go on.
    static let keys: [String] = {
        let word = Array("take1-3")
        let up = (1...word.count).map { String(word[0..<$0]) }
        let down = (0..<word.count - 1).reversed().map { String(word[0..<$0]) }
        let cycle = up + down
        return (0..<60).map { cycle[$0 % cycle.count] }
    }()

    /// The candidate list of the pane: an `NSTableView` over the row array (U2 fallback), one text
    /// cell per row. A SwiftUI `List` of the same rows took 140 ms per key (p95).
    @MainActor final class RowTable: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 260, height: 608))
        let table = NSTableView()
        var rows: [SessionIndex.Row] = []

        override init() {
            super.init()
            table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row")))
            table.headerView = nil
            table.rowHeight = 22
            table.dataSource = self
            table.delegate = self
            scroll.documentView = table
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
            let seconds = rows[row].position.count / 48_000
            let text = NSTextField(labelWithString: "\(rows[row].name)  \(seconds / 60):\(seconds % 60)")
            text.lineBreakMode = .byTruncatingTail
            return text
        }

        func show(_ rows: [SessionIndex.Row]) {
            self.rows = rows
            table.reloadData()
        }
    }

    /// The nearest rank p95 of the sorted times.
    static func p95(_ times: [Duration]) -> Duration { times.sorted()[Int(Double(times.count) * 0.95) - 1] }

    static func p50(_ times: [Duration]) -> Duration { times.sorted()[times.count / 2] }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aSearchKeyFitsOneFrameInTheModelAndAList() async throws {
        let session = try Self.session()
        let clock = ContinuousClock()
        var built: SessionIndex?
        let build = clock.measure { built = SessionIndex(session: session) }
        let index = try #require(built)
        try #require(index.rows.count == 12_250)
        print("SessionIndexBenchmark row build: \(build)")

        let list = RowTable()
        let hosting = list.scroll
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 608), styleMask: [.borderless], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.close() }
        list.show(index.rows)
        hosting.layoutSubtreeIfNeeded()
        drawNow(window)

        var filterTimes: [Duration] = []
        var listTimes: [Duration] = []
        for (n, key) in (Self.keys + Self.keys).enumerated() {
            var rows: [SessionIndex.Row] = []
            let filter = clock.measure { rows = index.rows(kind: nil, search: key) }
            let update = clock.measure {
                list.show(rows)
                hosting.layoutSubtreeIfNeeded()
                drawNow(window)
            }
            // The first 60 keys warm the window and are not timed.
            if n >= Self.keys.count {
                filterTimes.append(filter)
                listTimes.append(update)
            }
            try await Task.sleep(for: .microseconds(16_700))
        }
        let sum = zip(filterTimes, listTimes).map { $0 + $1 }
        print(
            "SessionIndexBenchmark search key p95: filter \(Self.p95(filterTimes)), list \(Self.p95(listTimes)), "
                + "sum \(Self.p95(sum)), sum p50 \(Self.p50(sum)), max \(sum.max()!)")
        expectWithinBudget(Self.p95(sum), Self.budget, "one search key, p95 \(Self.p95(sum))")
    }

    /// The control of the timed list: the table shows all rows and makes cells for the rows in view.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func theListShowsTheRows() async throws {
        let index = SessionIndex(session: try Self.session())
        let list = RowTable()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 608), styleMask: [.borderless], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = list.scroll
        window.orderFront(nil)
        defer { window.close() }
        list.show(index.rows)
        list.scroll.layoutSubtreeIfNeeded()
        drawNow(window)
        #expect(list.table.numberOfRows == 12_250)
        #expect(list.table.rows(in: list.table.visibleRect).length > 20)
        let cell = list.table.view(atColumn: 0, row: 0, makeIfNecessary: false) as? NSTextField
        #expect(cell?.stringValue.hasPrefix("take") == true)
    }
}
