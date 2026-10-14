import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The context menu of the lanes (decision 0037, criteria C16 and C20, `ui-panel.md` 4 and 5). The
/// lanes of `standaloneLanes` (512 frames per point, 100 pt lanes): c1 is x 0 to 1875 pt on t1
/// and c2 is on t2, each split at 48 000 and 96 000 (x 93.75 and 187.5 pt).
@Suite(.serialized) @MainActor struct LaneMenuTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws { folder = try TemporaryFolder() }

    func lanes() async throws -> (SessionWindow, Studio, NSWindow, TimelineScrollView) {
        let url = try await timelinePackage(in: folder.url, tracks: 2, seconds: 20)
        var session = try Session(contentsOf: url)
        _ = try session.splitClips(at: [48_000, 96_000], on: session.tracks.map(\.id))
        try session.write(to: url)
        let (model, studio) = try await timelineModel(url, app: app)
        let (window, view) = standaloneLanes(model, studio)
        return (model, studio, window, view)
    }

    func menu(_ view: TimelineScrollView, _ x: Double, _ y: Double) throws -> NSMenu {
        try #require(view.lanes.menu(for: try mouse(.rightMouseDown, NSPoint(x: x, y: y), in: view)))
    }

    /// The titles of the menu, with "-" for a separator, and "(off)" after a dimmed item.
    func titles(_ menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "-" : $0.title + ($0.isEnabled ? "" : " (off)") }
    }

    /// Control: another order, or one group.
    @Test func theGroupsAreInOrder() {
        let groups = LaneMenu.groups(
            selection: true, clips: false, clipboard: true, split: true, canEdit: true, canRipple: true)
        #expect(
            groups.map { $0.map(\.command) } == [
                [.cut, .copy, .paste, .insert], [.delete, .deleteCloseGap, .split, .fade], [.addMarker, .addChapter],
            ])
        let enabled = groups.joined().allSatisfy { $0.enabled }
        #expect(enabled)
    }

    /// Control: an item with a key equivalent, or an Undo item.
    @Test func theMenuHasNoKeys() async throws {
        let (model, _, _, view) = try await lanes()
        // The selection holds the split points 40 000 and 100 000 inside clips.
        model.timeline.marks = Marks(inPoint: 40_000, outPoint: 100_000, tracks: ["t1"])
        model.run(.copy)
        let menu = try menu(view, 120, 10)
        #expect(menu.items.allSatisfy { $0.keyEquivalent.isEmpty }, "\(menu.items.map(\.keyEquivalent))")
        #expect(!titles(menu).contains("Undo"))
        #expect(menu.items.count == 12, "\(titles(menu))")
        await model.close()
    }

    /// Only Cut, Copy, and Paste dim; the others hide. Control: a shown Delete with no selection.
    @Test func itemsThatDoNotApplyHide() {
        let none = LaneMenu.groups(
            selection: false, clips: false, clipboard: false, split: false, canEdit: true, canRipple: true)
        #expect(
            none.map { $0.map(\.command) } == [[.cut, .copy, .paste], [.addMarker, .addChapter]],
            "no selection, no clipboard, no clip at the playhead")
        #expect(none[0].map(\.enabled) == [false, false, false], "Cut, Copy, and Paste dim")
        let split = LaneMenu.groups(
            selection: false, clips: false, clipboard: true, split: true, canEdit: true, canRipple: true)
        #expect(
            split.map { $0.map(\.command) } == [[.cut, .copy, .paste, .insert], [.split], [.addMarker, .addChapter]])
    }

    /// During a take, only the marker group shows. Control: a shown edit item.
    @Test func aTakeHidesTheEditItems() {
        let take = LaneMenu.groups(
            selection: true, clips: false, clipboard: true, split: true, canEdit: false, canRipple: false)
        #expect(take.map { $0.map(\.command) } == [[.addMarker, .addChapter]])
    }

    /// Add Marker and Add Chapter add nothing during a take, so they are off then. Control: on
    /// with no take.
    @Test func aTakeTurnsTheMarkerItemsOff() {
        let take = LaneMenu.groups(
            selection: false, clips: false, clipboard: false, split: false, canEdit: false, canRipple: false)
        #expect(take.map { $0.map(\.enabled) } == [[false, false]], "during a take")
        let idle = LaneMenu.groups(
            selection: false, clips: false, clipboard: false, split: false, canEdit: true, canRipple: true)
        #expect(idle.last?.map(\.enabled) == [true, true], "no take")
    }

    /// C20: a pending or split take hides Cut, Insert, and Delete and Close Gap. Control: a shown
    /// ripple item.
    @Test func aPendingTakeHidesTheRippleItems() {
        let blocked = LaneMenu.groups(
            selection: true, clips: false, clipboard: true, split: true, canEdit: true, canRipple: false)
        #expect(
            blocked.map { $0.map(\.command) } == [
                [.copy, .paste], [.delete, .split, .fade], [.addMarker, .addChapter],
            ])
    }

    /// C20 in the window: the menu reads `Studio.canRipple`. A `<recording>` and the marker of a
    /// recovery attempt make a pending take with no finalize at the open. Control m10.
    @Test func aPendingTakeHidesTheRippleItemsOfTheMenu() async throws {
        let (model, _, view) = try await pendingLanes()
        model.timeline.marks = Marks(inPoint: 40_000, outPoint: 100_000, tracks: ["t1"])
        model.run(.copy)
        try #require(model.clipboard != nil)

        let shown = titles(try menu(view, 120, 10))

        let ripple = [TimelineCommand.insert, .deleteCloseGap].compactMap { TimelineCommand.menuItems[$0]?.title.text }
        #expect(
            ripple.count == 2 && !shown.contains { title in ripple.contains { title.hasPrefix($0) } },
            "RIPPLE-W6 the menu shows a ripple item under a pending take")
        await model.close()
    }

    /// The lanes of `lanes()` under a pending take: a `<recording>` (take 1, armed t1) and the marker
    /// of a recovery attempt, so the open does not finalize.
    func pendingLanes() async throws -> (SessionWindow, Studio, TimelineScrollView) {
        let url = try await timelinePackage(in: folder.url, tracks: 2, seconds: 20)
        var session = try Session(contentsOf: url)
        _ = try session.splitClips(at: [48_000, 96_000], on: session.tracks.map(\.id))
        try session.setRecording(Recording(take: 1, playheadFrame: 0, takeStartHostTimeNanos: 1, armedTracks: ["t1"]))
        try session.write(to: url)
        FileManager.default.createFile(atPath: url.appending(path: "recovery-attempt").path, contents: nil)
        let (model, studio) = try await timelineModel(url, app: app)
        let (_, view) = standaloneLanes(model, studio)
        try #require(studio.pendingTake != nil)
        return (model, studio, view)
    }

    /// C20 in the window: an Option press on a trim zone under a pending take beeps and starts no
    /// drag. The gesture reads `Studio.canRipple` at the first drag event.
    @Test func anOptionPressUnderAPendingTakeBeeps() async throws {
        let (model, studio, view) = try await pendingLanes()
        let before = studio.session
        var beeps = 0
        model.beep = { beeps += 1 }
        let box = try #require(view.lanes.clipFrame("c1"))
        let edge = NSPoint(x: box.maxX - 2, y: box.minY + 10)

        view.lanes.mouseDown(with: try mouse(.leftMouseDown, edge, in: view, flags: .option))
        view.lanes.mouseDragged(with: try mouse(.leftMouseDragged, NSPoint(x: edge.x - 20, y: edge.y), in: view))
        view.lanes.mouseUp(with: try mouse(.leftMouseUp, NSPoint(x: edge.x - 20, y: edge.y), in: view))

        #expect(beeps == 1 && studio.session == before, "RIPPLE-W11 an Option press under a pending take did not beep")
        await model.close()
    }

    /// Clip-set-clipboard C11: a clip set shows Cut and Copy, enabled. A pending or split take hides
    /// Insert and Delete and Close Gap, but not Cut: Cut of a set is no ripple. Control: the groups
    /// before this run have no Cut and no Copy for a set.
    @Test func aClipSetShowsCutAndCopy() {
        let set = LaneMenu.groups(
            selection: true, clips: true, clipboard: true, split: true, canEdit: true, canRipple: true)
        #expect(
            set.map { $0.map(\.command) } == [
                [.cut, .copy, .paste, .insert], [.delete, .split, .fade], [.addMarker, .addChapter],
            ])
        let enabled = set.joined().allSatisfy { $0.enabled }
        #expect(enabled, "Cut and Copy are enabled")
        let blocked = LaneMenu.groups(
            selection: true, clips: true, clipboard: true, split: true, canEdit: true, canRipple: false)
        #expect(
            blocked.map { $0.map(\.command) } == [
                [.cut, .copy, .paste], [.delete, .split, .fade], [.addMarker, .addChapter],
            ])
        let take = LaneMenu.groups(
            selection: true, clips: true, clipboard: true, split: true, canEdit: false, canRipple: false)
        #expect(take.map { $0.map(\.command) } == [[.addMarker, .addChapter]])
    }

    /// U8: a right-click on a clip outside the selection selects that clip, as a click does.
    /// Control: a menu on the old Marks.
    @Test func aRightClickOnAnUnselectedClipSelectsIt() async throws {
        let (model, _, _, view) = try await lanes()
        model.timeline.marks = Marks(inPoint: 0, outPoint: 1_000, tracks: ["t2"])
        _ = try menu(view, 120, 10)
        #expect(model.timeline.marks == Marks(inPoint: 48_000, outPoint: 96_000, tracks: ["t1"]))
        await model.close()
    }

    /// U8: inside the selection and in a gap, the Marks stay. Control: a right-click that selects
    /// the clip under it.
    @Test func aRightClickInTheSelectionKeepsIt() async throws {
        let (model, _, _, view) = try await lanes()
        let marks = Marks(inPoint: 20_000, outPoint: 120_000, tracks: ["t1", "t2"])
        model.timeline.marks = marks
        _ = try menu(view, 120, 10)
        #expect(model.timeline.marks == marks, "inside the selection")
        _ = try menu(view, 2_000, 10)
        #expect(model.timeline.marks == marks, "in a gap after the clips")
        await model.close()
    }

    /// U8: a Control-click starts no press: no gesture, and the Marks stay. Control: a press.
    @Test func aControlClickStartsNoPress() async throws {
        let (model, _, _, view) = try await lanes()
        let marks = Marks(inPoint: 0, outPoint: 1_000, tracks: ["t2"])
        model.timeline.marks = marks
        view.lanes.mouseDown(with: try mouse(.leftMouseDown, NSPoint(x: 120, y: 10), in: view, flags: .control))
        #expect(!view.gesture.isActive)
        view.lanes.mouseUp(with: try mouse(.leftMouseUp, NSPoint(x: 120, y: 10), in: view, flags: .control))
        #expect(model.timeline.marks == marks)
        await model.close()
    }

    /// Each item runs the command of its Edit or Markers item. Control: an item with no action.
    @Test func eachItemRunsItsCommand() async throws {
        let (model, _, _, view) = try await lanes()
        model.timeline.marks = Marks(inPoint: 40_000, outPoint: 100_000, tracks: ["t1"])
        model.run(.copy)
        let menu = try menu(view, 120, 10)
        model.leafCalls = []
        for item in menu.items {
            if let action = item.action, let target = item.target { NSApp.sendAction(action, to: target, from: item) }
        }
        #expect(
            model.leafCalls == [
                "cut", "copy", "paste", "insert", "delete", "deleteCloseGap", "split", "fade", "addMarker",
                "addChapter",
            ])
        await model.close()
    }
}

extension LaneMenuTests {
    /// Multi-clip-selection U11 and clip-set-clipboard C11: a right-click on a clip of the set keeps
    /// the set, and the menu has Cut, Copy, Delete, and Fade but no Delete and Close Gap. Control:
    /// a right-click on a clip outside the set selects that clip.
    @Test func aRightClickInAClipSetKeepsIt() async throws {
        let (model, _, _, view) = try await lanes()
        let set = Selection.clips(try #require(ClipSet(["c1", "c2@48000"])))
        model.timeline.selection = set
        let shown = titles(try menu(view, 50, 10))
        #expect(model.timeline.selection == set)
        #expect(
            shown == [
                "menu.edit.cut", "menu.edit.copy", "menu.edit.paste (off)", "-", "menu.edit.delete", "menu.edit.fade",
                "-", "menu.markers.add", "menu.markers.add.chapter",
            ])
        _ = try menu(view, 50, 110)
        #expect(model.timeline.marks == Marks(inPoint: 0, outPoint: 48_000, tracks: ["t2"]), "c2 is not in the set")
        await model.close()
    }
}
