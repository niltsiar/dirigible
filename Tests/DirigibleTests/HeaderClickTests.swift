import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import SwiftUI
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Run ui-polish criteria C14 to C16e and C18: a click on a track header selects its track, and a
/// double-click on the name, Return, or the Rename action renames it. The events go to the hit view
/// of the frame view, as `NSWindow.sendEvent` sends them in a key window.
@Suite(.serialized) @MainActor struct HeaderClickTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws {
        NSWindow.allowsAutomaticWindowTabbing = false
        folder = try TemporaryFolder()
    }

    /// A session window with the tracks t1 to t`tracks`, each with a clip of 20 s from 0.
    func open(tracks: Int = 2) async throws -> (SessionWindow, Studio, NSWindow, TimelineScrollView) {
        try await openLanes(app, try await timelinePackage(in: folder.url, tracks: tracks, seconds: 20))
    }

    /// A click at the window point `point`: `clicks` mouse-downs and mouse-ups with click counts 1
    /// to `clicks`. It returns the hit view of the first mouse-down.
    @discardableResult func click(_ point: NSPoint, clicks: Int = 1, in window: NSWindow) throws -> NSView {
        drawNow(window)
        let hit = try #require(window.contentView?.superview?.hitTest(point))
        func event(_ type: NSEvent.EventType, _ count: Int) throws -> NSEvent {
            try #require(
                NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: count, pressure: 1))
        }
        for count in 1...clicks {
            hit.mouseDown(with: try event(.leftMouseDown, count))
            hit.mouseUp(with: try event(.leftMouseUp, count))
        }
        drawNow(window)
        return hit
    }

    /// The window point at the row x `x` and the middle height of header row `row`.
    func rowPoint(_ row: Int, x: Double = 4, in view: TimelineScrollView) throws -> NSPoint {
        let laneHeight = try #require(view.lanes.inputs?.laneHeight)
        return view.headers.host.convert(NSPoint(x: x, y: (Double(row) + 0.5) * laneHeight), to: nil)
    }

    /// The name fields of the rows, top to bottom.
    func nameFields(_ view: TimelineScrollView) -> [NSTextField] {
        func fields(_ view: NSView) -> [NSTextField] {
            if let field = view as? NSTextField, field.isEditable { return [field] }
            return view.subviews.flatMap(fields)
        }
        return fields(view.headers.host).sorted {
            $0.convert($0.bounds, to: nil).midY > $1.convert($1.bounds, to: nil).midY
        }
    }

    /// The window point at the middle of the name field of row `row`. The layout runs first: the
    /// rows of a new window can still change their height, and a point from an old frame hit the
    /// row background.
    func namePoint(_ row: Int, in view: TimelineScrollView) throws -> NSPoint {
        view.window?.contentView?.layoutSubtreeIfNeeded()
        let fields = nameFields(view)
        try #require(fields.count > row, "a name field in row \(row)")
        let frame = fields[row].convert(fields[row].bounds, to: nil)
        return NSPoint(x: frame.midX, y: frame.midY)
    }

    /// True when the name field of row `row` has the text focus.
    func editsName(_ row: Int, in view: TimelineScrollView) -> Bool {
        let fields = nameFields(view)
        guard fields.count > row, let editor = view.window?.firstResponder as? NSTextView else { return false }
        return editor.delegate === fields[row]
    }

    @Test func aHeaderClickSelectsItsTrack() async throws {
        let (model, _, window, view) = try await open()
        try click(try rowPoint(1, in: view), in: window)
        #expect(model.timeline.selection == .range(Marks(tracks: ["t2"])))
        await model.close()
    }

    /// A selected row in a key window shows a light tint of the accent color, not a full fill. In
    /// another window the row keeps the unemphasized source list fill.
    @Test func theSelectedRowStyle() throws {
        let key = HeaderRowStyle(selected: true, emphasized: true)
        let fill = try #require(key.fill)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let (tint, accent) = (try Self.rgba(fill, in: name), try Self.rgba(.controlAccentColor, in: name))
            #expect(
                zip(tint, accent).prefix(3).allSatisfy { abs($0 - $1) < 0.01 },
                "the tint has the accent color in \(name.rawValue): \(tint) against \(accent)")
            #expect((0.1...0.35).contains(tint[3]), "the tint is light in \(name.rawValue): alpha \(tint[3])")
        }
        let other = HeaderRowStyle(selected: true, emphasized: false)
        #expect(other.fill == .unemphasizedSelectedContentBackgroundColor)
        for emphasized in [true, false] {
            let style = HeaderRowStyle(selected: false, emphasized: emphasized)
            #expect(style.fill == nil, "no fill for a row that is not selected")
        }
    }

    /// The red, green, blue, and alpha of `color` in the appearance `name`, in sRGB.
    private static func rgba(_ color: NSColor, in name: NSAppearance.Name) throws -> [CGFloat] {
        let appearance = try #require(NSAppearance(named: name))
        var converted: NSColor?
        appearance.performAsCurrentDrawingAppearance { converted = color.usingColorSpace(.sRGB) }
        let resolved = try #require(converted)
        return [resolved.redComponent, resolved.greenComponent, resolved.blueComponent, resolved.alphaComponent]
    }

    /// C15: a header click with a focused name field commits the typed name and ends the focus.
    @Test func aHeaderClickCommitsTheName() async throws {
        let (model, studio, window, view) = try await open()
        let editor = try await focusName(in: window)
        editor.selectAll(nil)
        editor.insertText("Guest", replacementRange: editor.selectedRange())
        await until("the typed name is a draft") { model.drafts["t1"] == "Guest" }

        try click(try rowPoint(1, in: view), in: window)

        #expect(studio.session.track("t1")?.name == "Guest", "the click commits the name")
        #expect(window.firstResponder !== editor, "the click ends the focus")
        #expect(model.timeline.selection == .range(Marks(tracks: ["t2"])))
        // The end of the edit writes the text of the field to its draft. A commit before it left
        // the old name as a draft, and the next commit gave the old name back.
        try await Task.sleep(for: .milliseconds(100))
        drawNow(window)
        model.commitDrafts()
        #expect(studio.session.track("t1")?.name == "Guest", "a later commit keeps the name")
        await model.close()
    }

    /// C16 and C16c: a range drag over the same lane runs no header body and no row body; a click
    /// from t1 to t2 runs 2 row bodies or fewer.
    @Test func aRangeDragRunsNoRowBody() async throws {
        let (model, _, window, view) = try await open()
        let laneHeight = try #require(view.lanes.inputs?.laneHeight)
        // The lower part of the clip box is the range zone.
        let y = laneHeight * 0.9
        view.lanes.mouseDown(with: try mouse(.leftMouseDown, NSPoint(x: 100, y: y), in: view))
        /// One drag event, and the SwiftUI update of the pane that it causes.
        func drag(_ x: Double) async throws {
            let updates = view.updates
            view.lanes.mouseDragged(with: try mouse(.leftMouseDragged, NSPoint(x: x, y: y), in: view))
            await until("the pane updates") {
                window.contentView?.layoutSubtreeIfNeeded()
                return view.updates > updates
            }
        }
        try await drag(110)
        try #require(model.timeline.selection.headerTracks(in: try #require(model.studio).session) == ["t1"])
        model.headerRuns = (0, 0)
        for n in 1...10 { try await drag(110 + Double(n) * 10) }
        drawNow(window)
        #expect(model.headerRuns.headers == 0, "no header body during the drag: \(model.headerRuns.headers)")
        #expect(model.headerRuns.rows == 0, "no row body during the drag: \(model.headerRuns.rows)")
        view.lanes.mouseUp(with: try mouse(.leftMouseUp, NSPoint(x: 210, y: y), in: view))

        model.headerRuns.rows = 0
        try click(try rowPoint(1, in: view), in: window)
        await until("the rows show the click") {
            window.contentView?.layoutSubtreeIfNeeded()
            return model.headerRuns.rows > 0
        }
        #expect(model.headerRuns.rows <= 2, "a click runs \(model.headerRuns.rows) row bodies")
        await model.close()
    }

    /// C16d: a click on the name selects the track and gives no text focus; a double-click focuses
    /// the name field. The two clicks come with no time between them, also when the first click
    /// changes the selection: the header host takes the second click and gives the focus once.
    @Test func aNameClickSelectsAndADoubleClickRenames() async throws {
        let (model, _, window, view) = try await open()
        try click(try namePoint(1, in: view), clicks: 2, in: window)
        #expect(model.renamingTrack == "t2", "a double-click that also selects the track renames")
        await until(limit: .seconds(5), "a double-click focuses the name field of t2") { editsName(1, in: view) }

        try click(try namePoint(0, in: view), in: window)
        #expect(model.timeline.selection == .range(Marks(tracks: ["t1"])))
        #expect(!editsName(0, in: view) && model.renamingTrack == nil, "a click gives no text focus")

        try click(try namePoint(0, in: view), clicks: 2, in: window)
        #expect(model.renamingTrack == "t1")
        await until(limit: .seconds(5), "a double-click focuses the name field") { editsName(0, in: view) }
        await model.close()
    }

    /// C16e: Track > Rename Track (Return) focuses the name of the selected track. With no track or
    /// a clip set, it beeps. The commit ends the rename, so a later click on the name selects.
    @Test func returnRenamesTheSelectedTrack() async throws {
        let (model, studio, window, view) = try await open()
        let item = try #require(TimelineCommand.trackItems.first { $0.command == .renameTrack })
        #expect(item.key == .return && item.modifiers == [] && TimelineCommand.renameTrack.forwardsKey)
        var beeps = 0
        model.beep = { beeps += 1 }
        model.run(.renameTrack)
        model.timeline.selection = .clips(try #require(ClipSet(["c1"])))
        model.run(.renameTrack)
        #expect(beeps == 2 && model.renamingTrack == nil, "no track and a clip set beep")

        model.timeline.selection = .range(Marks(tracks: ["t2"]))
        model.run(.renameTrack)
        #expect(model.renamingTrack == "t2")
        await until(limit: .seconds(5), "Return focuses the name field") { editsName(1, in: view) }
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("Host", replacementRange: editor.selectedRange())
        editor.insertNewline(nil)
        #expect(studio.session.track("t2")?.name == "Host" && model.renamingTrack == nil, "Return commits")
        // Return ends the rename: a later key goes to the lanes, not to the name (code gate 1 item 1).
        #expect(window.firstResponder === view.lanes, "Return gives the focus to the lanes")
        try click(try namePoint(1, in: view), in: window)
        #expect(!editsName(1, in: view), "after the commit a click gives no text focus")
        #expect(model.timeline.selection == .range(Marks(tracks: ["t2"])))
        await model.close()
    }

    /// C18: Select All shows every row selected, and Deselect All shows none. The test window is
    /// not key, so the rows show the unemphasized fill.
    @Test func selectAllSelectsEveryRow() async throws {
        let (model, _, window, view) = try await open()
        window.appearance = NSAppearance(named: .aqua)
        func rowPixels() async throws -> [UInt32] {
            drawNow(window)
            try await Task.sleep(for: .milliseconds(200))
            let capture = try await TimelineColorTests.capture(window)
            return try (0..<2).map { row in
                let point = try rowPoint(row, in: view)
                return try #require(
                    TimelineRulerTests.pixels(
                        of: NSRect(x: point.x, y: point.y, width: 0.5, height: 0.5), capture, window
                    ).first)
            }
        }
        let before = try await rowPixels()
        model.run(.selectAll)
        let all = try await rowPixels()
        #expect(zip(before, all).allSatisfy { $0 != $1 }, "each row shows the fill: \(before) \(all)")
        model.run(.deselectAll)
        #expect(try await rowPixels() == before, "no row shows the fill")
        await model.close()
    }
}
