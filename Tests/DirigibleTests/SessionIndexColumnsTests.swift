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
        #expect(shownColumns(table) == ["name", "start"], "name and start only: no Track column by default")
        #expect(table.tableColumns.prefix(2).map(\.title) == [L10n.markerName.text, L10n.indexColumnStart.text])
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

    func shownColumns(_ table: NSTableView) -> [String] {
        table.tableColumns.filter { !$0.isHidden }.map(\.identifier.rawValue)
    }

    /// The text of each cell of column `id` in the rows a, h1, m1, b, c, m2.
    func texts(_ id: String, in table: NSTableView) -> [String] {
        let column = table.column(withIdentifier: NSUserInterfaceItemIdentifier(id))
        guard column >= 0 else { return ["no column"] }
        return (0..<table.numberOfRows).map {
            (table.view(atColumn: column, row: $0, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue
                ?? "no cell"
        }
    }

    /// The menu of a Control-click or a right-click on the column header.
    func headerMenu(of table: NSTableView, in window: NSWindow) throws -> NSMenu {
        let header = try #require(table.headerView)
        let event = try #require(
            NSEvent.mouseEvent(
                with: .rightMouseDown, location: NSPoint(x: 20, y: 10), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        return try #require(header.menu(for: event), "the header has a menu")
    }

    @Test func theHeaderMenuShowsAColumn() async throws {
        let windows = try SessionIndexWindowTests()
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, _, window) = try await windows.open()
        let table = try #require(model.leadingPane.table)
        await until("the table shows its rows") { table.numberOfRows == 6 }
        var menu = try headerMenu(of: table, in: window)
        #expect(
            menu.items.map(\.title) == [L10n.indexColumnTrack, .indexColumnDuration, .indexColumnEnd].map(\.text),
            "Track, Duration, and End; Name and Start always show")
        #expect(menu.items.allSatisfy { $0.state == .off })
        menu.performActionForItem(at: 1)
        #expect(windows.app.indexColumns.shown == [.duration])
        #expect(shownColumns(table) == ["name", "start", "duration"])
        // a, h1 (to the session end), m1, b, c, m2
        #expect(texts("duration", in: table) == ["0:00:02.000", "0:00:05.000", "", "0:00:02.000", "0:00:02.000", ""])
        menu = try headerMenu(of: table, in: window)
        #expect(menu.items.map(\.state) == [.off, .on, .off], "the menu shows the choice")
        menu.performActionForItem(at: 2)
        menu.performActionForItem(at: 0)
        #expect(shownColumns(table) == ["name", "start", "track", "duration", "end"])
        #expect(texts("end", in: table) == ["0:00:02.000", "0:00:06.000", "", "0:00:03.000", "0:00:06.000", ""])
        #expect(texts("track", in: table) == ["Host", "", "", "Guest", "Host", ""])
        #expect(Array(table.tableColumns.map(\.title).suffix(3)) == menu.items.map(\.title), "a header says its column")
        try headerMenu(of: table, in: window).performActionForItem(at: 1)
        #expect(shownColumns(table) == ["name", "start", "track", "end"], "a second choice hides the column")
        #expect(windows.app.indexColumns.shown == [.track, .end])
        await model.close()
    }

    @Test func theColumnsAreAnAppPreference() async throws {
        let windows = try SessionIndexWindowTests()
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        #expect(windows.defaults.object(forKey: "index.columns") == nil, "nothing is stored before a choice")
        windows.app.indexColumns.toggle(.end)
        windows.app.indexColumns.toggle(.track)
        #expect(windows.defaults.stringArray(forKey: "index.columns") == ["track", "end"])
        let relaunched = AppDelegate(recordings: nil, defaults: windows.defaults)
        #expect(relaunched.indexColumns.shown == [.track, .end], "the choice stays after a relaunch")
        let (model, _, _, _) = try await openLanes(relaunched, try await windows.package())
        model.toggleIndex()
        await until("the table shows") { model.leadingPane.table != nil }
        let table = try #require(model.leadingPane.table)
        #expect(shownColumns(table) == ["name", "start", "track", "end"], "a new window opens with the choice")
        await model.close()
        windows.defaults.set("duration", forKey: "index.columns")
        #expect(AppDelegate(recordings: nil, defaults: windows.defaults).indexColumns.shown == [], "a stored string")
        windows.defaults.set(["end", "name", "gone"], forKey: "index.columns")
        #expect(AppDelegate(recordings: nil, defaults: windows.defaults).indexColumns.shown == [.end])
    }

    @Test func anOpenWindowFollowsTheColumns() async throws {
        let windows = try SessionIndexWindowTests()
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (first, _, window) = try await windows.open()
        let (second, _, _, _) = try await openLanes(windows.app, try await windows.package())
        second.toggleIndex()
        await until("the second table shows") { second.leadingPane.table != nil }
        let (one, two) = (try #require(first.leadingPane.table), try #require(second.leadingPane.table))
        #expect(shownColumns(one) == ["name", "start"] && shownColumns(two) == ["name", "start"])
        try headerMenu(of: one, in: window).performActionForItem(at: 1)
        await until("the open second window shows Duration") { shownColumns(two) == ["name", "start", "duration"] }
        #expect(shownColumns(one) == ["name", "start", "duration"])
        await first.close()
        await second.close()
    }

    /// A trim of the end of clip c moves the session end: the Duration and End cells of c and of the
    /// chapter h1 change in the rows that the table holds, and the table does not reload.
    @Test func aTrimShowsTheNewDurationsWithNoReload() async throws {
        let windows = try SessionIndexWindowTests()
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        windows.app.indexColumns.toggle(.duration)
        windows.app.indexColumns.toggle(.end)
        let (model, studio, window) = try await windows.open()
        let table = try #require(model.leadingPane.table)
        await until("the table shows its rows") { table.numberOfRows == 6 }
        #expect(texts("duration", in: table)[4] == "0:00:02.000")
        let reloads = table.reloads
        model.edit(ripple: false) { s throws(SessionError) in try s.trim("c", to: 192_000..<240_000) }
        let rows = SessionIndex(session: studio.session).rows
        await until("the list shows the trim") { (table.dataSource as? IndexTableSource)?.rows == rows }
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(table.reloads == reloads, "no reloadData")
        #expect(texts("duration", in: table) == ["0:00:02.000", "0:00:04.000", "", "0:00:02.000", "0:00:01.000", ""])
        #expect(texts("end", in: table) == ["0:00:02.000", "0:00:05.000", "", "0:00:03.000", "0:00:05.000", ""])
        windows.app.indexColumns.toggle(.duration)
        await until("the column hides") {
            table.tableColumn(withIdentifier: SessionIndexTable.durationColumn)?.isHidden == true
        }
        model.edit(ripple: false) { s throws(SessionError) in try s.trim("c", to: 192_000..<216_000) }
        await until("the list shows the second trim") {
            (table.dataSource as? IndexTableSource)?.rows[4].duration == 24_000
        }
        windows.app.indexColumns.toggle(.duration)
        await until("the column shows") {
            table.tableColumn(withIdentifier: SessionIndexTable.durationColumn)?.isHidden == false
        }
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(texts("duration", in: table) == ["0:00:02.000", "0:00:03.500", "", "0:00:02.000", "0:00:00.500", ""])
        await model.close()
    }

    /// The open time field shows the whole time: the room of its text is not less than the width of
    /// the text. The widest time is two hour digits.
    @Test func theTimeFieldShowsAWholeTime() async throws {
        let windows = try SessionIndexWindowTests()
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, studio, window) = try await windows.open()
        let table = try #require(model.leadingPane.table)
        await until("the table shows its rows") { table.numberOfRows == 6 }
        for (frames, text) in [(1_152_000, "0:00:24.000"), (2_174_245_872, "12:34:56.789")] {
            try studio.edit(ripple: false) { session throws(SessionError) in
                try session.setMarker(Marker(id: "m1", name: "Breath", position: Frames(frames), kind: .marker))
            }
            await until("the list has the time") {
                (table.dataSource as? IndexTableSource)?.rows.contains { $0.position.count == frames } == true
            }
            model.beginRowEdit("m1", field: .start)
            await until("the time field opens") {
                windows.views(NSTextField.self, in: table).contains { $0.isEditable }
            }
            window.contentView?.layoutSubtreeIfNeeded()
            let field = try #require(windows.views(NSTextField.self, in: table).first { $0.isEditable })
            let cell = try #require(field.cell)
            let room = cell.titleRect(forBounds: field.bounds).width
            let need = field.attributedStringValue.size().width
            #expect(field.stringValue == text)
            #expect(need <= room, "\(text): the text needs \(need) pt of \(room) pt")
            model.finishRowEdit(save: false)
            await until("the field closes") { !windows.views(NSTextField.self, in: table).contains { $0.isEditable } }
        }
        await model.close()
    }
}
