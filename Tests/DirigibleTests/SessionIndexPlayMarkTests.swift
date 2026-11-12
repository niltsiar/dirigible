import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The play mark of the index list. The fixture is that of `SessionIndexWindowTests`: the rows are
/// a (0), h1, m1, b (48,000), c (192,000), and m2 (240,000). With `markers`, 40 more markers show.
@Suite(.serialized) @MainActor struct SessionIndexPlayMarkTests {
    let base: SessionIndexWindowTests

    init() throws { base = try SessionIndexWindowTests() }

    static let play = Playback.playing(Shuttle(direction: .forward, rate: .one))

    /// The window with the list shown. The display link does not tick the lanes here, so a test gives
    /// each tick. With `markers`, the 40 more markers show.
    func open(markers: Bool = false) async throws -> (SessionWindow, Studio, TimelineScrollView, IndexTableView) {
        let (model, studio, window) = try await base.open()
        let view = try #require(model.timelineView)
        view.linkProxy?.view = nil
        let table = try #require(model.leadingPane.table)
        if markers { try base.addMarkers(to: studio) }
        await until("the table shows its rows") { table.numberOfRows == (markers ? 46 : 6) }
        window.contentView?.layoutSubtreeIfNeeded()
        return (model, studio, view, table)
    }

    /// The head of a stopped tick.
    func at(_ frame: Int, _ view: TimelineScrollView) { view.tick(playhead: Double(frame), playback: .stopped) }

    @Test func theLineIsAtTheHead() async throws {
        defer { base.defaults.removePersistentDomain(forName: base.suite) }
        let (model, _, view, table) = try await open()
        let mark = table.mark
        at(50_000, view)
        #expect(mark.row == 3, "the head at 50,000 is under b")
        let line = mark.line.frame
        #expect(
            abs(line.midY - table.rect(ofRow: 3).maxY) < 0.5 && line.height == 1, "the line is under row b: \(line)")
        #expect(abs(line.midY - table.rect(ofRow: 4).minY) < 3, "the line is over row c")
        #expect(line.width == table.bounds.width, "the line spans the table")
        at(47_999, view)
        #expect(mark.row == 0, "the head at 47,999 is under a")
        #expect(abs(mark.line.frame.midY - table.rect(ofRow: 0).maxY) < 0.5)

        model.leadingPane.kind = .marker
        await until("the Markers filter shows m1 and m2") { table.numberOfRows == 2 }
        at(50_000, view)
        #expect(mark.row == 0 && abs(mark.line.frame.midY - table.rect(ofRow: 0).maxY) < 0.5, "under m1, over m2")
        at(10_000, view)
        #expect(mark.row == nil && mark.line.frame.minY == 0, "before the first shown row the line is at the top")
        await model.close()
    }

    @Test func aSeekWhileStoppedMovesTheMark() async throws {
        defer { base.defaults.removePersistentDomain(forName: base.suite) }
        let (model, studio, view, table) = try await open()
        view.linkProxy?.view = view
        await studio.perform(.seek(.frame(200_000)))
        await until("the mark moves to row c") { table.mark.row == 4 }
        await studio.perform(.seek(.frame(0)))
        await until("the mark moves to row a") { table.mark.row == 0 }
        await model.close()
    }

    @Test func theTintIsOnTheCurrentRow() async throws {
        defer { base.defaults.removePersistentDomain(forName: base.suite) }
        let (model, _, view, table) = try await open()
        let mark = table.mark
        at(50_000, view)
        #expect(mark.tint.frame == table.rect(ofRow: 3) && !mark.tint.isHidden, "the tint is on b, not on c")
        at(47_999, view)
        #expect(mark.tint.frame == table.rect(ofRow: 0), "the tint is on a")
        #expect(mark.tint.superlayer === table.layer && mark.line.superlayer === table.layer)
        model.leadingPane.kind = .marker
        await until("the Markers filter shows m1 and m2") { table.numberOfRows == 2 }
        at(10_000, view)
        #expect(mark.tint.isHidden, "no row starts at or before the head")
        await model.close()
    }

    @Test func theListFollowsOnlyWithFollow() async throws {
        defer { base.defaults.removePersistentDomain(forName: base.suite) }
        let (model, _, view, table) = try await open(markers: true)
        let clip = try #require(table.enclosingScrollView?.contentView)
        let top = clip.bounds.minY
        model.timeline.follows = false
        for step in 0...120 { view.tick(playhead: Double(step * 20_000), playback: Self.play) }
        #expect(table.mark.row == 45, "the mark is on the last row")
        #expect(clip.bounds.minY == top, "Follow off: the list does not scroll")

        model.timeline.follows = true
        at(0, view)
        #expect(clip.bounds.minY == top)
        for step in 0...120 { view.tick(playhead: Double(step * 20_000), playback: Self.play) }
        let current = table.rect(ofRow: 45)
        #expect(clip.bounds.minY > top && clip.bounds.intersects(current), "Follow on: the list shows the current row")
        await model.close()
    }

    @Test func aListScrollHoldsTheIndexFollow() async throws {
        defer { base.defaults.removePersistentDomain(forName: base.suite) }
        let (model, _, view, table) = try await open(markers: true)
        let scroll = try #require(table.enclosingScrollView)
        let mark = table.mark
        let top = scroll.contentView.bounds.minY
        func userScroll(to y: Double) {
            NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        }
        at(0, view)
        run(view, from: 1, to: 2)
        userScroll(to: top)
        #expect(mark.hold.isEmpty, "a live scroll with no move holds nothing")
        userScroll(to: top + 100)
        #expect(mark.hold == .listScroll, "a list scroll during play holds the index follow")
        run(view, from: 3, to: 123)
        #expect(scroll.contentView.bounds.minY == top + 100, "120 ticks past the last row in view: no scroll")
        #expect(!model.timeline.followHeld, "the lanes hold is apart from the list hold")

        at(0, view)
        run(view, from: 1, to: 123)
        #expect(mark.hold.isEmpty, "a play start ends the hold")
        #expect(scroll.contentView.bounds.minY > top + 100, "Stop and Play: the list scrolls")

        at(0, view)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: top))
        scroll.reflectScrolledClipView(scroll.contentView)
        run(view, from: 1, to: 2)
        model.leadingPane.search = "Mark"
        await runLoopPass()
        #expect(mark.hold == .search, "a search key during play holds the index follow")
        let shown = scroll.contentView.bounds.minY
        run(view, from: 3, to: 123)
        #expect(scroll.contentView.bounds.minY == shown, "a search key during play: no scroll")
        await model.close()
    }

    @Test func theMarkIsNoAccessibilityElement() async throws {
        defer { base.defaults.removePersistentDomain(forName: base.suite) }
        let (model, _, view, table) = try await open()
        let children = {
            (table.accessibilityChildren() ?? []).map { child in
                (child as? NSAccessibilityProtocol).map {
                    "\($0.accessibilityRole()?.rawValue ?? ""): \($0.accessibilityLabel() ?? "")"
                }
            }
        }
        let before = children()
        at(50_000, view)
        at(200_000, view)
        #expect(!before.isEmpty && children() == before, "the accessibility children of the table do not change")
        #expect(table.subviews.allSatisfy { $0 is NSTableRowView }, "the table holds only its rows: \(table.subviews)")
        #expect(table.layer?.sublayers?.contains(table.mark.line) == true, "the mark is a layer")
        await model.close()
    }

    /// The play ticks `first` to `last`, each 20,000 frames after the one before.
    func run(_ view: TimelineScrollView, from first: Int, to last: Int) {
        for step in first...last { view.tick(playhead: Double(step * 20_000), playback: Self.play) }
    }

    /// The index follow holds while a row field is open, and the hold clears at the field end.
    @Test func aRowFieldHoldsTheFollow() async throws {
        defer { base.defaults.removePersistentDomain(forName: base.suite) }
        let (model, _, view, table) = try await open(markers: true)
        let window = try #require(table.window)
        base.app.key = model
        let clip = try #require(table.enclosingScrollView?.contentView)
        let top = clip.bounds.minY
        try base.click(row: 2, table, in: window)
        at(0, view)
        run(view, from: 1, to: 2)
        base.app.timeline(.renameTrack, event: key(.keyDown, "\r", code: 36, in: window), in: window)
        try #require(model.leadingPane.rowEdit != nil, "the field opens")
        #expect(table.mark.hold.contains(.rowField), "the field holds the follow")
        run(view, from: 3, to: 123)
        #expect(clip.bounds.minY == top, "120 ticks past the last row in view: no scroll with the field open")

        base.app.timeline(.renameTrack, event: key(.keyDown, "\r", code: 36, in: window), in: window)
        #expect(table.mark.hold.isEmpty, "the field end clears the hold")
        run(view, from: 100, to: 100)
        #expect(clip.bounds.minY > top, "the next tick that changes the current row scrolls")
        await model.close()
    }

    /// The index follow holds while a row context menu is open.
    @Test func aRowMenuHoldsTheFollow() async throws {
        defer { base.defaults.removePersistentDomain(forName: base.suite) }
        let (model, _, view, table) = try await open(markers: true)
        let clip = try #require(table.enclosingScrollView?.contentView)
        let top = clip.bounds.minY
        let rect = table.rect(ofRow: 2)
        let click = NSEvent.mouseEvent(
            with: .rightMouseDown, location: table.convert(NSPoint(x: rect.minX + 30, y: rect.midY), to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: try #require(table.window).windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1)!
        let menu = try #require(table.menu(for: click), "a marker row has a menu")
        let delegate = try #require(menu.delegate)
        at(0, view)
        run(view, from: 1, to: 2)
        delegate.menuWillOpen?(menu)
        #expect(table.mark.hold.contains(.rowMenu), "the open menu holds the follow")
        run(view, from: 3, to: 123)
        #expect(clip.bounds.minY == top, "120 ticks past the last row in view: no scroll with the menu open")

        delegate.menuDidClose?(menu)
        #expect(table.mark.hold.isEmpty, "the menu close clears the hold")
        run(view, from: 100, to: 100)
        #expect(clip.bounds.minY > top, "the next tick that changes the current row scrolls")
        await model.close()
    }
}
