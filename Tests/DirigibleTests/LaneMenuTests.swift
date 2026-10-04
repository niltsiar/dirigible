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
        let groups = LaneMenu.groups(selection: true, clipboard: true, split: true, canEdit: true, canRipple: true)
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
        let none = LaneMenu.groups(selection: false, clipboard: false, split: false, canEdit: true, canRipple: true)
        #expect(
            none.map { $0.map(\.command) } == [[.cut, .copy, .paste], [.addMarker, .addChapter]],
            "no selection, no clipboard, no clip at the playhead")
        #expect(none[0].map(\.enabled) == [false, false, false], "Cut, Copy, and Paste dim")
        let split = LaneMenu.groups(selection: false, clipboard: true, split: true, canEdit: true, canRipple: true)
        #expect(
            split.map { $0.map(\.command) } == [[.cut, .copy, .paste, .insert], [.split], [.addMarker, .addChapter]])
    }

    /// During a take, only the marker group shows. Control: a shown edit item.
    @Test func aTakeHidesTheEditItems() {
        let take = LaneMenu.groups(selection: true, clipboard: true, split: true, canEdit: false, canRipple: false)
        #expect(take.map { $0.map(\.command) } == [[.addMarker, .addChapter]])
    }

    /// C20: a pending or split take hides Cut, Insert, and Delete and Close Gap. Control: a shown
    /// ripple item.
    @Test func aPendingTakeHidesTheRippleItems() {
        let blocked = LaneMenu.groups(selection: true, clipboard: true, split: true, canEdit: true, canRipple: false)
        #expect(
            blocked.map { $0.map(\.command) } == [
                [.copy, .paste], [.delete, .split, .fade], [.addMarker, .addChapter],
            ])
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
