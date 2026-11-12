import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The double click on a row of the index list and the action Play from here. The rows of the
/// fixture are a (0), h1 (1), m1 (2), b (3), c (4), and m2 (5).
extension SessionIndexWindowTests {
    /// A double click as a mouse sends it: a pair with count 1, then a pair with count 2.
    func doubleClick(row n: Int, _ table: NSTableView, in window: NSWindow) throws {
        try click(row: n, table, in: window)
        try click(row: n, table, in: window, clicks: 2)
    }

    /// Stopped, a double click on c plays from its start. During play, the play goes on from
    /// the row start. On a marker row it opens no rename field and no Marker Info.
    @Test func aDoubleClickPlaysFromTheRow() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, studio, window, table) = try await openRows()
        let inspector = model.showsInspector
        await studio.perform(.seek(.frame(60_000)))
        try doubleClick(row: 4, table, in: window)
        await model.settleTransport()
        #expect(studio.playback != .stopped, "the play starts")
        #expect(studio.playhead >= 192_000 && studio.playhead < 192_000 + 48_000, "from the start of c")
        #expect(model.timeline.selection == .clips(ClipSet("c")) && model.timeline.selectedRows == [.clip("c")])

        try doubleClick(row: 2, table, in: window)
        await model.settleTransport()
        #expect(studio.playback != .stopped, "(during play) the play goes on")
        #expect(studio.playhead >= 48_000 && studio.playhead < 48_000 + 48_000, "from the start of m1")
        #expect(model.timeline.marker == "m1" && model.timeline.selectedRows == [.marker("m1")])
        #expect(model.leadingPane.rowEdit == nil, "no rename field")
        #expect(model.showsInspector == inspector, "no Marker Info")
        await studio.perform(.playStop)

        await studio.perform(.seek(.frame(300_000)))
        try doubleClick(row: 2, table, in: window)
        await model.settleTransport()
        #expect(studio.playback != .stopped && studio.playhead < 96_000, "(stopped) a marker row plays from m1")
        #expect(model.leadingPane.rowEdit == nil, "no rename field")
        await studio.perform(.playStop)
        await model.close()
    }

    /// During a take, and the pre-roll of a pre-roll take, a double click only selects.
    @Test(arguments: [false, true])
    func aDoubleClickDuringATakeOnlySelects(preRoll: Bool) async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, studio, window, table) = try await openRows(routed: true)
        studio.environment = hal.environment
        if preRoll { await model.recordPreRoll() } else { await model.record() }
        try #require(!studio.isIdle, "the take runs")
        let head = studio.playhead
        model.leafCalls = []
        try doubleClick(row: 4, table, in: window)
        await model.settleTransport()
        #expect(model.timeline.selection == .clips(ClipSet("c")), "the selection changes")
        #expect(studio.playhead == head && head != 192_000, "the playhead stays")
        #expect(model.leafCalls == [], "no seek and no play start: \(model.leafCalls ?? [])")
        #expect(!studio.isIdle, "the take goes on")
        await model.stop()
        await until("the take finalizes") { studio.transport == .idle }
        await model.close()
    }

    /// The action Play from here and the row menu item do what a double click does.
    @Test func playFromHereActsAsADoubleClick() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, studio, window, table) = try await openRows()
        func action(row n: Int) throws -> NSAccessibilityCustomAction {
            try #require(
                table.rowView(atRow: n, makeIfNecessary: true)?.accessibilityCustomActions()?.first {
                    $0.name == L10n.indexActionPlayFromHere.text
                })
        }
        _ = try action(row: 4).handler?()
        await model.settleTransport()
        #expect(studio.playback != .stopped, "the action starts the play")
        #expect(studio.playhead >= 192_000 && studio.playhead < 192_000 + 48_000, "from the start of c")
        #expect(model.timeline.selectedRows == [.clip("c")])
        await studio.perform(.playStop)

        let rect = table.rect(ofRow: 2)
        let point = table.convert(NSPoint(x: rect.minX + 30, y: rect.midY), to: nil)
        let right = try #require(
            NSEvent.mouseEvent(
                with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let item = try #require(table.menu(for: right)?.items.first { $0.title == L10n.indexMenuPlayFromHere.text })
        _ = item.target?.perform(item.action, with: item)
        await model.settleTransport()
        #expect(studio.playback != .stopped && model.timeline.marker == "m1", "the menu item plays from m1")
        #expect(model.leadingPane.rowEdit == nil)
        await studio.perform(.playStop)
        await model.close()
    }
}
