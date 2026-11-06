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
            selection: true, clips: false, stereo: false, denoise: false, restore: false, clipboard: true, split: true,
            canEdit: true,
            canRipple: true)
        #expect(
            groups.map { $0.map(\.command) } == [
                [.cut, .copy, .paste, .fill, .insert, .replace], [.delete, .deleteCloseGap, .split, .fade],
                [.addMarker, .addChapter],
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
        #expect(menu.items.count == 16, "\(titles(menu))")
        await model.close()
    }

    /// Only Cut, Copy, and Paste dim; the others hide. Control: a shown Delete with no selection.
    @Test func itemsThatDoNotApplyHide() {
        let none = LaneMenu.groups(
            selection: false, clips: false, stereo: false, denoise: false, restore: false, clipboard: false,
            split: false,
            canEdit: true,
            canRipple: true)
        #expect(
            none.map { $0.map(\.command) } == [[.cut, .copy, .paste], [.addMarker, .addChapter]],
            "no selection, no clipboard, no clip at the playhead")
        #expect(none[0].map(\.enabled) == [false, false, false], "Cut, Copy, and Paste dim")
        let split = LaneMenu.groups(
            selection: false, clips: false, stereo: false, denoise: false, restore: false, clipboard: true, split: true,
            canEdit: true,
            canRipple: true)
        #expect(
            split.map { $0.map(\.command) } == [[.cut, .copy, .paste, .insert], [.split], [.addMarker, .addChapter]])
    }

    /// During a take, only the marker group shows. Control: a shown edit item.
    @Test func aTakeHidesTheEditItems() {
        let take = LaneMenu.groups(
            selection: true, clips: false, stereo: false, denoise: false, restore: false, clipboard: true, split: true,
            canEdit: false,
            canRipple: false
        )
        #expect(take.map { $0.map(\.command) } == [[.addMarker, .addChapter]])
    }

    /// The lane menu reads the rule of the Markers menu, so the marker items are on while a take
    /// records. Control: on with no take.
    @Test func aTakeKeepsTheMarkerItemsOn() async throws {
        let (model, studio, window, view) = try await lanes()
        let marker = [L10n.menuMarkersAdd.text, L10n.menuMarkersAddChapter.text]
        #expect(Array(titles(try menu(view, 120, 10)).suffix(2)) == marker, "no take")

        studio.transport = .recording(take: 1)
        defer { studio.transport = .idle }
        #expect(titles(try menu(view, 120, 10)) == marker, "during a take")
        window.close()
        await model.close()
    }

    /// C20: a pending or split take hides Cut, Insert, and Delete and Close Gap. Control: a shown
    /// ripple item.
    @Test func aPendingTakeHidesTheRippleItems() {
        let blocked = LaneMenu.groups(
            selection: true, clips: false, stereo: false, denoise: false, restore: false, clipboard: true, split: true,
            canEdit: true,
            canRipple: false)
        #expect(
            blocked.map { $0.map(\.command) } == [
                [.copy, .paste, .fill], [.delete, .split, .fade], [.addMarker, .addChapter],
            ])
    }

    /// C18: Paste to Fill Selection follows Paste and shows with a range, dimmed with no clipboard.
    /// Replace follows Insert and shows with a range and a clipboard when a ripple can run. A clip
    /// set and no selection show neither. Control: Replace with no clipboard, or under a pending
    /// take.
    @Test func replaceAndFillShowWithARange() {
        func commands(
            selection: Bool = true, clips: Bool = false, clipboard: Bool = true, ripple: Bool = true
        ) -> [[LaneMenu.Item]] {
            LaneMenu.groups(
                selection: selection, clips: clips, stereo: false, denoise: false, restore: false,
                clipboard: clipboard, split: false, canEdit: true, canRipple: ripple)
        }
        func first(_ groups: [[LaneMenu.Item]]) -> [LaneMenu.Item] { groups[0] }
        #expect(first(commands()).map(\.command) == [.cut, .copy, .paste, .fill, .insert, .replace])
        #expect(first(commands(clipboard: false)).filter { $0.command == .fill }.map(\.enabled) == [false])
        #expect(!first(commands(clipboard: false)).map(\.command).contains(.replace))
        #expect(!first(commands(ripple: false)).map(\.command).contains(.replace))
        #expect(first(commands(ripple: false)).map(\.command).contains(.fill))
        for shown in [commands(clips: true), commands(selection: false)] {
            #expect(!shown.joined().map(\.command).contains { $0 == .fill || $0 == .replace })
        }
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
            selection: true, clips: true, stereo: false, denoise: false, restore: false, clipboard: true, split: true,
            canEdit: true,
            canRipple: true)
        #expect(
            set.map { $0.map(\.command) } == [
                [.cut, .copy, .paste, .insert], [.delete, .split, .fade], [.addMarker, .addChapter],
            ])
        let enabled = set.joined().allSatisfy { $0.enabled }
        #expect(enabled, "Cut and Copy are enabled")
        let blocked = LaneMenu.groups(
            selection: true, clips: true, stereo: false, denoise: false, restore: false, clipboard: true, split: true,
            canEdit: true,
            canRipple: false)
        #expect(
            blocked.map { $0.map(\.command) } == [
                [.cut, .copy, .paste], [.delete, .split, .fade], [.addMarker, .addChapter],
            ])
        let take = LaneMenu.groups(
            selection: true, clips: true, stereo: false, denoise: false, restore: false, clipboard: true, split: true,
            canEdit: false,
            canRipple: false)
        #expect(take.map { $0.map(\.command) } == [[.addMarker, .addChapter]])
    }

    /// U8: a right-click on a clip outside the selection selects that clip, as a click does.
    /// Control: a menu on the old Marks.
    @Test func aRightClickOnAnUnselectedClipSelectsIt() async throws {
        let (model, _, _, view) = try await lanes()
        model.timeline.marks = Marks(inPoint: 0, outPoint: 1_000, tracks: ["t2"])
        _ = try menu(view, 120, 10)
        #expect(model.timeline.selection == .clips(ClipSet("c1@48000")))
        await model.close()
    }

    /// Run split-no-cut criterion C5: a right-click on c1@48000 selects it as a clip set, and Split shows
    /// when the playhead is inside the clip. Control: with the playhead after the clip, Split hides.
    @Test func aRightClickOnAClipShowsSplitWithThePlayheadInIt() async throws {
        let (model, studio, _, view) = try await lanes()
        func commands(_ menu: NSMenu) -> [TimelineCommand] {
            menu.items.compactMap { $0.representedObject as? TimelineCommand }
        }

        await studio.perform(.seek(.frame(60_000)))
        #expect(commands(try menu(view, 120, 10)).contains(.split))
        model.timeline.selection = .none
        await studio.perform(.seek(.frame(200_000)))
        #expect(!commands(try menu(view, 120, 10)).contains(.split))
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
                "cut", "copy", "paste", "fill", "insert", "replace", "delete", "deleteCloseGap", "split",
                "reduceNoise", "repairSound", "fade", "addMarker", "addChapter",
            ])
        await model.close()
    }
}

extension LaneMenuTests {
    /// C18: Split Stereo to Mono follows Split in group 2 only with a stereo clip, and hides with the
    /// edit items during a take. Control: the same call with `stereo` false.
    @Test func splitStereoShowsOnlyWithAStereoClip() {
        func commands(stereo: Bool, canEdit: Bool = true) -> [[TimelineCommand]] {
            LaneMenu.groups(
                selection: true, clips: true, stereo: stereo, denoise: false, restore: false, clipboard: false,
                split: true,
                canEdit: canEdit,
                canRipple: true
            ).map { $0.map(\.command) }
        }
        #expect(
            commands(stereo: true) == [
                [.cut, .copy, .paste], [.delete, .split, .splitStereo, .fade], [.addMarker, .addChapter],
            ])
        #expect(commands(stereo: false)[1] == [.delete, .split, .fade])
        #expect(commands(stereo: true, canEdit: false) == [[.addMarker, .addChapter]])
    }

    /// C13: Reduce Noise and Repair Sound follow Split Stereo to Mono in group 2 only when the
    /// selection holds a clip that they take, and hide with the edit items during a take. Control:
    /// the same call with `denoise` false.
    @Test func reduceNoiseShowsOnlyWithAClipItTakes() {
        func group(denoise: Bool, stereo: Bool = false) -> [TimelineCommand] {
            LaneMenu.groups(
                selection: true, clips: true, stereo: stereo, denoise: denoise, restore: false, clipboard: false,
                split: true,
                canEdit: true, canRipple: true
            )[1].map(\.command)
        }
        #expect(group(denoise: true) == [.delete, .split, .reduceNoise, .repairSound, .fade])
        #expect(
            group(denoise: true, stereo: true) == [.delete, .split, .splitStereo, .reduceNoise, .repairSound, .fade])
        #expect(group(denoise: false) == [.delete, .split, .fade])
        let take = LaneMenu.groups(
            selection: true, clips: true, stereo: false, denoise: true, restore: false, clipboard: false, split: true,
            canEdit: false,
            canRipple: false)
        #expect(take.map { $0.map(\.command) } == [[.addMarker, .addChapter]])
    }

    /// C6 (decision 0057): Restore Original Audio follows Reduce Noise in group 2 only when the
    /// selection holds a clip on a rendered file, and hides with the edit items during a take.
    /// Control: the same call with `restore` false.
    @Test func restoreShowsOnlyWithARenderedClip() {
        func group(restore: Bool, denoise: Bool = true) -> [TimelineCommand] {
            LaneMenu.groups(
                selection: true, clips: true, stereo: false, denoise: denoise, restore: restore, clipboard: false,
                split: true, canEdit: true, canRipple: true
            )[1].map(\.command)
        }
        #expect(group(restore: true) == [.delete, .split, .reduceNoise, .repairSound, .restoreOriginal, .fade])
        #expect(group(restore: true, denoise: false) == [.delete, .split, .restoreOriginal, .fade])
        #expect(group(restore: false) == [.delete, .split, .reduceNoise, .repairSound, .fade])
        let take = LaneMenu.groups(
            selection: true, clips: true, stereo: false, denoise: true, restore: true, clipboard: false, split: true,
            canEdit: false, canRipple: false)
        #expect(take.map { $0.map(\.command) } == [[.addMarker, .addChapter]])
    }

    /// Multi-clip-selection U11 and clip-set-clipboard C11: a right-click on a clip of the set keeps
    /// the set, and the menu has Cut, Copy, Delete, Fade, and Close Gaps but no Delete and Close Gap. Control:
    /// a right-click on a clip outside the set selects that clip.
    @Test func aRightClickInAClipSetKeepsIt() async throws {
        let (model, _, _, view) = try await lanes()
        let set = Selection.clips(try #require(ClipSet(["c1", "c2@48000"])))
        model.timeline.selection = set
        let shown = titles(try menu(view, 50, 10))
        #expect(model.timeline.selection == set)
        #expect(
            shown == [
                "menu.edit.cut", "menu.edit.copy", "menu.edit.paste (off)", "-", "menu.edit.delete",
                "menu.tools.reduce.noise", "menu.tools.repair.sound", "menu.edit.fade", "menu.edit.close.gaps", "-",
                "menu.markers.add", "menu.markers.add.chapter",
            ])
        _ = try menu(view, 50, 110)
        #expect(model.timeline.selection == .clips(ClipSet("c2")), "c2 is not in the set")
        await model.close()
    }
}
