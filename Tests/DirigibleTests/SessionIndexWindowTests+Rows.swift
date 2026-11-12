import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The row actions of the index list, the selected rows, and the edits from other sources. The
/// rows of the fixture are a (0), h1, m1, b (48,000), c (192,000), and m2 (240,000), in that order.
extension SessionIndexWindowTests {
    static let order: [SessionIndex.Pick] = [
        .clip("a"), .marker("h1"), .marker("m1"), .clip("b"), .clip("c"), .marker("m2"),
    ]
    static let starts: [Frames] = [0, 48_000, 48_000, 48_000, 192_000, 240_000]

    /// The window with the list shown, its six rows loaded, and the list as first responder.
    func openRows(routed: Bool = false) async throws -> (SessionWindow, Studio, NSWindow, NSTableView) {
        let (model, studio, window) = try await open(routed: routed)
        let table = try #require(model.leadingPane.table)
        await until("the table shows its rows") { table.numberOfRows == 6 }
        window.contentView?.layoutSubtreeIfNeeded()
        try #require(window.makeFirstResponder(table), "the list takes the focus")
        return (model, studio, window, table)
    }

    /// A click on row `n`, through the window as a mouse does.
    func click(
        row n: Int, _ table: NSTableView, in window: NSWindow, flags: NSEvent.ModifierFlags = [], clicks: Int = 1
    ) throws {
        window.contentView?.layoutSubtreeIfNeeded()
        let rect = table.rect(ofRow: n)
        let point = table.convert(NSPoint(x: rect.minX + 30, y: rect.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(
                NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: clicks, pressure: 1))
            window.sendEvent(event)
        }
    }

    /// Up Arrow (126) or Down Arrow (125) through the window.
    func arrow(_ down: Bool, shift: Bool = false, in window: NSWindow) throws {
        let scalar = Character(UnicodeScalar(down ? NSDownArrowFunctionKey : NSUpArrowFunctionKey)!)
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero,
                modifierFlags: shift ? [.shift, .numericPad, .function] : [.numericPad, .function],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: String(scalar),
                charactersIgnoringModifiers: String(scalar), isARepeat: false, keyCode: down ? 125 : 126))
        window.sendEvent(event)
    }

    func table(_ table: NSTableView, shows n: Int) -> Bool { table.selectedRow == n }

    /// The first test (criterion X9): the rows follow a lane edit and a row click.
    @Test func theRowsFollowEachEdit() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, _, window, table) = try await openRows()
        let before = model.timeline.rowsRevision
        model.timeline.selection = .clips(ClipSet(["a"])!)
        #expect(model.timeline.selectedRows == [.clip("a")], "a lane click on a")
        model.timeline.selection = model.timeline.selection.toggling("c", in: model.studio!.session)
        #expect(model.timeline.selectedRows == [.clip("a"), .clip("c")], "a lane Command-click on c")
        model.timeline.marker = "h1"
        #expect(model.timeline.selectedRows == [.marker("h1")], "Next Marker: the last write wins")
        model.timeline.selection = .range(Marks(inPoint: 0, outPoint: 24_000))
        #expect(model.timeline.selectedRows.isEmpty, "a Marks range shows no row")
        #expect(model.timeline.rowsRevision == before + 4, "each lane write raises the revision once")

        try click(row: 4, table, in: window)
        #expect(model.timeline.selectedRows == [.clip("c")] && table.selectedRow == 4, "a click on row c")
        try click(row: 2, table, in: window)
        #expect(model.timeline.selectedRows == [.marker("m1")] && table.selectedRow == 2, "a click on row m1")
        try click(row: 4, table, in: window)
        #expect(model.timeline.selectedRows == [.clip("c")], "row c again, though the selection was {c}")
        try click(row: 2, table, in: window)
        try click(row: 2, table, in: window)
        #expect(model.timeline.selectedRows == [.marker("m1")], "row m1 again, though the marker was m1")
        await model.close()
    }

    /// X5. A click on a clip row selects the clip set, seeks to the clip start, and shows it; the
    /// current marker stays. During a take, and the pre-roll of a pre-roll take, the playhead stays.
    @Test func aClipRowSelectsAndSeeks() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, studio, window, table) = try await openRows()
        model.timeline.marker = "m2"
        await studio.perform(.seek(.frame(300_000)))
        try click(row: 4, table, in: window)
        await model.settleTransport()
        #expect(model.timeline.selection == .clips(ClipSet("c")), "(a) the selection is the clip set of c")
        #expect(studio.playhead == 192_000, "(a) the playhead was after the clip")
        #expect(model.timeline.marker == "m2", "the current marker does not change")

        let lanes = try #require(model.timelineView)
        lanes.navigate(.zoom(by: 0.02))
        lanes.scroll(toFrame: 0)
        await until("the lanes show the start only") {
            drawNow(window)
            return lanes.origin == 0 && lanes.visibleFrames < 192_000
        }
        try click(row: 3, table, in: window)
        await model.settleTransport()
        try click(row: 4, table, in: window)
        await model.settleTransport()
        await until("(b) the view shows the clip start") {
            drawNow(window)
            return lanes.origin <= 192_000 && 192_000 < lanes.origin + lanes.visibleFrames
        }
        await model.close()
    }

    @Test func aClipRowDuringPlayKeepsThePlay() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, studio, window, table) = try await openRows()
        await studio.perform(.seek(.start))
        await studio.perform(.playStop)
        try #require(studio.playback != .stopped, "the play runs")
        try click(row: 4, table, in: window)
        await model.settleTransport()
        #expect(studio.playback != .stopped, "(c) the play goes on")
        #expect(studio.playhead >= 192_000 && studio.playhead < 192_000 + 48_000, "(c) from the clip start")
        await studio.perform(.playStop)
        await model.close()
    }

    @Test(arguments: [false, true])
    func aRowDuringATakeKeepsThePlayhead(preRoll: Bool) async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, studio, window, table) = try await openRows(routed: true)
        studio.environment = hal.environment
        if preRoll { await model.recordPreRoll() } else { await model.record() }
        try #require(!studio.isIdle, "(d) the take runs")
        let head = studio.playhead
        let lanes = try #require(model.timelineView)
        lanes.navigate(.zoom(by: 0.02))
        lanes.scroll(toFrame: 0)
        await until("the lanes show the start only") {
            drawNow(window)
            return lanes.origin == 0 && lanes.visibleFrames < 192_000
        }
        try click(row: 4, table, in: window)
        await model.settleTransport()
        drawNow(window)
        #expect(lanes.origin == 0, "the view stays during the take")
        #expect(model.timeline.selection == .clips(ClipSet("c")), "the selection changes")
        #expect(studio.playhead == head && head != 192_000, "the playhead stays during the take")
        try click(row: 2, table, in: window)
        #expect(model.timeline.marker == "m1" && studio.playhead == head, "a marker row during the take")
        await model.stop()
        await until("the take finalizes") { studio.transport == .idle }
        await model.close()
    }

    /// X6. A click on a marker row sets the current marker and seeks; the selection stays.
    @Test func aMarkerRowSetsTheCurrentMarker() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, studio, window, table) = try await openRows()
        model.timeline.selection = .clips(ClipSet("a"))
        try click(row: 5, table, in: window)
        await model.settleTransport()
        #expect(model.timeline.marker == "m2" && studio.playhead == 240_000)
        #expect(model.timeline.selection == .clips(ClipSet("a")), "the selection does not change")
        #expect(model.timeline.selectedRows == [.marker("m2")])
        await model.close()
    }

    /// X7. Down Arrow after m1 selects b, the row after m1, and seeks to it.
    @Test func theArrowsMoveTheRow() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, studio, window, table) = try await openRows()
        try click(row: 4, table, in: window)
        try click(row: 2, table, in: window)
        try arrow(true, in: window)
        await model.settleTransport()
        #expect(model.timeline.selection == .clips(ClipSet("b")), "Down Arrow after m1 selects b")
        #expect(model.timeline.selectedRows == [.clip("b")] && studio.playhead == 48_000)
        try click(row: 0, table, in: window)
        try arrow(false, in: window)
        #expect(model.timeline.selectedRows == [.clip("a")], "Up Arrow at the first row keeps the row")
        await model.close()
    }

    @Test func theArrowsDoNotSeekDuringPlay() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, studio, window, table) = try await openRows()
        try click(row: 2, table, in: window)
        await model.settleTransport()
        await studio.perform(.seek(.frame(60_000)))
        await studio.perform(.playStop)
        try #require(studio.playback != .stopped, "the play runs")
        try arrow(true, in: window)
        await model.settleTransport()
        #expect(model.timeline.selection == .clips(ClipSet("b")), "the arrow selects b")
        #expect(studio.playhead != 48_000 && studio.playhead >= 60_000, "the play position does not jump")
        await studio.perform(.playStop)
        await model.close()
    }

    /// X9. A lane write pushes the rows once and seeks nowhere.
    @Test func aLaneSelectionPushesRowsWithNoSeek() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, studio, _, table) = try await openRows()
        model.timeline.selection = .clips(ClipSet("a"))
        let (revision, pushes) = (model.timeline.rowsRevision, model.leadingPane.pushes)
        let head = studio.playhead
        model.timeline.selection = model.timeline.selection.toggling("c", in: studio.session)
        await model.settleTransport()
        #expect(model.timeline.selectedRows == [.clip("a"), .clip("c")])
        #expect(studio.playhead == head, "a lane write does not seek")
        #expect(model.timeline.rowsRevision == revision + 1 && model.leadingPane.pushes == pushes + 1, "one push")
        #expect(table.selectedRow == 4, "the list shows the anchor row c")
        await model.close()
    }

    @Test func theLaneFormTakesTheAnchorFromTheWrite() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, studio, _, _) = try await openRows()
        let session = studio.session
        model.timeline.selection = .clips(ClipSet("a"))
        #expect(model.timeline.anchorRow == .clip("a"))
        model.timeline.selection = model.timeline.selection.toggling("c", in: session)
        #expect(model.timeline.anchorRow == .clip("c"), "the clip that the write adds")
        model.timeline.selection = .clips(ClipSet(["a", "c"])!)
        #expect(model.timeline.anchorRow == .clip("c"), "a write that adds no clip keeps c while c is selected")
        model.timeline.selection = .clips(ClipSet("a"))
        #expect(model.timeline.anchorRow == nil, "a write that adds no clip, when the old anchor c is not selected")
        model.timeline.selection = .none
        #expect(model.timeline.anchorRow == nil, "no clip left")
        model.timeline.marker = "m2"
        #expect(model.timeline.anchorRow == .marker("m2"), "a marker write: the new current marker")
        await model.close()
    }

    /// X26. An undo of an Add leaves the playhead; no row is selected.
    @Test func undoOfAnAddLeavesThePlayhead() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, studio, _, table) = try await openRows()
        await studio.perform(.seek(.frame(96_000)))
        model.run(.addMarker)
        await until("the marker is added") { studio.session.markers.count == 4 }
        await until("the list shows 7 rows") { table.numberOfRows == 7 }
        try #require(model.timeline.selectedRows.count == 1, "the new marker is the current one")
        model.undo()
        await until("the undo removes the marker") { studio.session.markers.count == 3 }
        await until("the rows follow") { model.timeline.selectedRows.isEmpty }
        await model.settleTransport()
        #expect(studio.playhead == 96_000, "the undo did not seek")
        #expect(table.numberOfRows == 6 && table.selectedRow == -1)
        await model.close()
    }

    @Test func anOutsideEditKeepsTheMarks() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, studio, _, _) = try await openRows()
        let marks = Marks(inPoint: 48_000, outPoint: 144_000, tracks: ["t1"])
        model.timeline.selection = .range(marks)
        let revision = studio.sessionRevision
        model.edit(ripple: false) { s throws(SessionError) in
            guard var marker = s.markers["m1"] else { return }
            marker.name = "Renamed"
            try s.setMarker(marker)
        }
        await until("the rows follow the session") {
            model.leadingPane.reconciles > 0 && studio.sessionRevision > revision
        }
        #expect(model.timeline.selection == .range(marks), "the Marks stay")
        await model.close()
    }

    @Test func anOutsideEditKeepsTheCurrentMarker() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, studio, _, _) = try await openRows()
        model.timeline.marker = "m1"
        model.timeline.selection = .clips(ClipSet("a"))
        model.edit(ripple: false) { s throws(SessionError) in try s.removeClips(["b"]) }
        await until("the rows follow the session") { model.leadingPane.reconciles > 0 }
        #expect(studio.session.tracks[1].clips.isEmpty)
        #expect(model.timeline.selection == .clips(ClipSet("a")) && model.timeline.marker == "m1")
        await model.close()
    }

    @Test func anOutsideEditKeepsTheValidRows() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, _, window, table) = try await openRows()
        model.timeline.selection = .clips(ClipSet("b"))
        model.timeline.selection = .clips(ClipSet(["b", "c"])!)
        try #require(model.timeline.selectedRows == [.clip("b"), .clip("c")] && model.timeline.anchorRow == .clip("c"))
        model.edit(ripple: false) { s throws(SessionError) in try s.removeClips(["c"]) }
        await until("the rows follow the session") { model.timeline.selectedRows == [.clip("b")] }
        #expect(model.timeline.anchorRow == .clip("b"), "the anchor moves to the first row that stays")
        #expect(window.firstResponder === table, "the focus stays in the list")
        await model.close()
    }

    @Test func aGoneRowIsAnnounced() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, studio, _, _) = try await openRows()
        model.timeline.marker = "m2"
        var posts: [String] = []
        model.leadingPane.announce = { posts.append($0) }
        model.edit(ripple: false) { s throws(SessionError) in try s.removeMarker("m2") }
        await until("the rows follow the session") { model.timeline.selectedRows.isEmpty }
        #expect(posts == [L10n.indexPostSelectedGone.text], "VoiceOver says that the item is gone")
        #expect(model.timeline.anchorRow == nil && studio.session.markers["m2"] == nil)
        await model.close()
    }

    /// X23. Delete in the lanes runs the lane Delete only: a selected marker row stays.
    @Test func deleteInTheLanesKeepsTheMarkerRows() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, studio, window, table) = try await openRows()
        try click(row: 2, table, in: window)
        try #require(window.makeFirstResponder(model.timelineView?.lanes))
        model.timeline.marker = "m1"
        model.timeline.selection = .clips(ClipSet("a"))
        app.timeline(.delete, event: key(.keyDown, "\u{7f}", code: 51, in: window), in: window)
        await until("the clip goes") { studio.session.tracks[0].clips.count == 1 }
        #expect(studio.session.markers["m1"] != nil, "the marker stays")
        await model.close()
    }

    /// X12. Each row has the actions Go to, Show Info, and Play from here; a marker or chapter row
    /// also has Rename. No row has Delete in this landing.
    @Test func aRowHasItsCustomActions() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, _, _, table) = try await openRows()
        let clips = [L10n.indexActionGoTo.text, L10n.indexActionShowInfo.text]
        for n in 0..<6 {
            let row = try #require(table.rowView(atRow: n, makeIfNecessary: true))
            let names = (row.accessibilityCustomActions() ?? []).map(\.name)
            let renames = [1, 2, 5].contains(n)
            let expected = clips + (renames ? [L10n.headerRename.text] : []) + [L10n.indexActionPlayFromHere.text]
            #expect(names == expected, "row \(n): \(names)")
        }
        let row = try #require(table.rowView(atRow: 2, makeIfNecessary: true))
        _ = row.accessibilityCustomActions()?.first { $0.name == L10n.indexActionGoTo.text }?.handler?()
        #expect(model.timeline.selectedRows == [.marker("m1")], "Go to acts as a click")
        await model.close()
    }
}
