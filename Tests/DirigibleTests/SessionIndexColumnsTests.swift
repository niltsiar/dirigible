import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp

/// The columns of the index list.
@Suite(.serialized) @MainActor struct SessionIndexColumnsTests {
    @Test func theDefaultColumnsAreNameAndStart() async throws {
        let windows = try SessionIndexWindowTests()
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, _, _) = try await windows.open()
        let table = try #require(model.leadingPane.table)
        #expect(table.tableColumns.map(\.identifier.rawValue) == ["name", "start"], "name and start only")
        #expect(table.tableColumns.map(\.title) == [L10n.markerName.text, L10n.indexColumnStart.text])
        await until("the table shows its rows") { table.numberOfRows == 6 }
        let start = try #require(table.view(atColumn: 1, row: 3, makeIfNecessary: true) as? NSTableCellView)
        #expect(start.textField?.stringValue == "0:00:01.000", "b starts at 48,000 frames")
        let name = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView)
        #expect(name.textField?.stringValue == "Capture/take1-1-1", "the clip name, not the file ID")
        await model.close()
    }

    /// A ripple delete before 300 marker rows moves each of them by 10,000 frames: each row that the
    /// table holds shows its new start and says it, and the table does not reload.
    @Test func aRippleShowsTheNewStartsWithNoReload() async throws {
        let windows = try SessionIndexWindowTests()
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, studio, window) = try await windows.open()
        let table = try #require(model.leadingPane.table)
        try studio.edit(ripple: false) { session throws(SessionError) in
            for n in 0..<300 {
                try session.setMarker(
                    Marker(
                        id: MarkerID("x\(n)"), name: "Mark \(n)", position: Frames(250_000 + n * 4_800), kind: .marker))
            }
        }
        await until("the table shows its rows") { table.numberOfRows == 306 }
        table.scrollRowToVisible(150)
        window.contentView?.layoutSubtreeIfNeeded()
        let reloads = table.reloads
        model.edit(ripple: true) { s throws(SessionError) in
            try s.rippleDelete(100_000..<110_000, on: ["t1", "t2"], naming: ["t1", "t2"])
        }
        let rows = SessionIndex(session: studio.session).rows
        await until("the list shows the ripple") { (table.dataSource as? IndexTableSource)?.rows == rows }
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(table.reloads == reloads, "no reloadData")
        var (held, stale) = (0, [Int]())
        table.enumerateAvailableRowViews { view, n in
            held += 1
            let start = table.view(atColumn: 1, row: n, makeIfNecessary: false) as? NSTableCellView
            if start?.textField?.stringValue != timeDisplayText(rows[n].position, rate: 48_000, playing: false)
                || table.spokenLabel(row: n) != IndexTableSource.spoken(rows[n], rate: 48_000)
            {
                stale.append(n)
            }
        }
        #expect(held >= 10 && stale.isEmpty, "\(held) rows held, stale: \(stale.prefix(10))")
        await model.close()
    }
}
