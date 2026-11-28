import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Multi-clip-selection C9 and C11 in the window (decision 0038). The fixture of
/// `EditCommandWindowTests`, with c1 split at 48,000: the set {c1, c2}; c1@48000 on t1 and c3 on
/// t3 are not in it.
extension EditCommandWindowTests {
    func openSet() async throws -> (SessionWindow, Studio, NSWindow, TimelineScrollView) {
        let opened = try await open()
        try opened.1.edit(ripple: false) { session throws(SessionError) in _ = try session.split("c1", at: 48_000) }
        opened.0.timeline.selection = .clips(try #require(ClipSet(["c1", "c2"])))
        return opened
    }

    func ids(_ studio: Studio) -> [[ClipID]] { studio.session.tracks.map { $0.clips.map(\.id) } }

    /// C11a, C11e, C11f, C11g, C12, and clip-set-clipboard C10: the ripple items beep on a set.
    /// Control: a hull Delete removes c1@48000.
    @Test func eachEditOnAClipSelection() async throws {
        let (model, studio, _, _) = try await openSet()
        var beeps = 0
        model.beep = { beeps += 1 }
        let before = studio.session
        for command in [TimelineCommand.deleteCloseGap, .cutSelectedTracks, .deleteCloseGapSelectedTracks] {
            model.run(command)
        }
        #expect(beeps == 3 && studio.session == before && model.clipboard == nil, "beeps \(beeps)")
        model.run(.removeTrack)
        #expect(studio.session == before && !model.canPlaceAtPlayhead, "C11h: a clip set picks no track")
        #expect(model.timeline.selection == .clips(try #require(ClipSet(["c1", "c2"]))), "the set stays")

        await studio.perform(.seek(.frame(24_000)))
        model.run(.split)
        #expect(
            ids(studio) == [["c1", "c1@24000", "c1@48000"], ["c2", "c2@24000"], ["c3"]], "the set clips at the playhead"
        )
        model.undo()

        model.run(.delete)
        #expect(ids(studio) == [["c1@48000"], [], ["c3"]])
        #expect(model.timeline.selection == .none)
        model.undo()
        #expect(studio.session == before)

        model.timeline.marks = Marks(inPoint: 0, outPoint: 48_000, tracks: ["t3"])
        model.run(.copy)
        model.timeline.selection = .clips(try #require(ClipSet(["c2"])))
        model.run(.paste)
        #expect(studio.session.track("t2")?.clips.count == 3, "the paste goes on t2, the first set track")
        #expect(studio.session.track("t1") == before.track("t1") && studio.session.track("t3") == before.track("t3"))
        await model.close()
    }

    /// C9: a group drag is one undo entry.
    @Test func aGroupMoveIsOneUndoEntry() async throws {
        let (model, studio, window, view) = try await openSet()
        let before = studio.session
        view.update(laneInputs(model, studio, selection: model.timeline.selection))
        drawNow(window)
        let box = try #require(view.lanes.clipFrame("c1"))
        let start = NSPoint(x: box.midX, y: box.minY + 10)
        view.lanes.mouseDown(with: try mouse(.leftMouseDown, start, in: view))
        let end = NSPoint(x: start.x + 20, y: start.y + box.height)
        view.lanes.mouseDragged(with: try mouse(.leftMouseDragged, end, in: view))
        view.lanes.mouseUp(with: try mouse(.leftMouseUp, end, in: view))
        #expect(studio.session.clip("c1")?.track == "t2" && studio.session.clip("c2")?.track == "t3")
        model.undo()
        #expect(studio.session == before, "one undo puts both clips back")
        await model.close()
    }

    /// Clip-set-clipboard C6 to C9. Controls: a ripple Cut moves c3 and c1@48000 left; a Copy that
    /// beeps fails the beep count.
    @Test func copyCutAndPasteOfAClipSet() async throws {
        let (model, studio, _, _) = try await openSet()
        let set = model.timeline.selection
        var beeps = 0
        model.beep = { beeps += 1 }
        let before = studio.session
        let excerpt = try studio.session.excerpt(of: ["c1", "c2"])

        model.run(.copy)
        #expect(model.clipboard == excerpt && excerpt.kind == .clips, "C6a: only c1 and c2")
        #expect(studio.session == before && beeps == 0, "no edit and no beep")

        await studio.perform(.seek(.frame(960_000)))
        model.run(.paste)
        #expect(
            ids(studio) == [["c1", "c1@48000", "c1@960000", "c1@48000@1008000"], ["c2", "c2@960000"], ["c3"]],
            "C8a: c1 and c2 keep their offsets from the first set track")
        #expect(model.timeline.selection == .clips(try #require(ClipSet(["c1@960000", "c2@960000"]))), "C8c")
        model.undo()
        #expect(studio.session == before, "C8e: one undo entry")

        model.timeline.selection = .none
        model.run(.paste)
        #expect(studio.session.clip("c1@960000")?.track == "t1" && studio.session.clip("c2@960000")?.track == "t2")
        model.undo()

        model.timeline.selection = .clips(try #require(ClipSet(["c3"])))
        model.run(.paste)
        let added = try #require(studio.session.tracks.last)
        #expect(studio.session.tracks.count == before.tracks.count + 1 && model.alert == nil, "C8d: a new last track")
        #expect(added.name == before.track("t2")?.name && added.clips.map(\.id) == ["c2@960000"], "C8d")
        #expect(model.clipboard == excerpt)
        model.undo()
        #expect(studio.session == before)

        model.timeline.selection = set
        model.run(.insert)
        let inserted = model.timeline.selection.selectedClips(in: studio.session).map(\.clip)
        #expect(inserted.map(\.start) == [960_000, 960_000] && inserted.map(\.length) == [48_000, 2_880_000], "C9")
        #expect(studio.session.track("t3")?.clips.last?.start == 3_840_000, "C9: every track moves")
        model.undo()
        #expect(studio.session == before)

        model.timeline.selection = .clips(try #require(ClipSet(["c1", "c2", "gone"])))
        app.clipboard = nil
        model.run(.cut)
        #expect(ids(studio) == [["c1@48000"], [], ["c3"]], "C7: gaps, c1@48000 and c3 do not move")
        #expect(studio.session.clip("c1@48000")?.clip.start == 48_000 && studio.session.clip("c3")?.clip.start == 0)
        #expect(model.clipboard == excerpt, "C6d: the stale ID drops")
        #expect(model.timeline.selection == .none && beeps == 0)
        await studio.settle()
        #expect(studio.playhead == 960_000, "C7: the playhead stays")
        model.undo()
        #expect(studio.session == before, "C7: one undo entry")
        await model.close()
    }

    func ranges(_ studio: Studio, _ track: TrackID) -> [Range<Frames>] {
        studio.session.track(track)?.clips.map(\.range) ?? []
    }

    /// C16: Duplicate (decision 0053) is on with a range on a track or a clip set, and it needs no
    /// clipboard. Control: with a range with no track, one point, a stale set, no selection, a take,
    /// a paste run, or no session window, it is off.
    @Test func duplicateMenuStates() async throws {
        let (model, studio, _, _) = try await open()
        let range = Marks(inPoint: 96_000, outPoint: 240_000, tracks: ["t2"])
        let set = try #require(ClipSet(["c1", "c2"]))
        let stale = try #require(ClipSet(["gone"]))
        let cases: [(String, Selection, Bool)] = [
            ("a range on a track", .range(range), true), ("a clip set", .clips(set), true),
            ("a range with no track", .range(Marks(inPoint: 96_000, outPoint: 240_000)), false),
            ("one point", .range(Marks(inPoint: 96_000, tracks: ["t2"])), false),
            ("a stale set", .clips(stale), false), ("no selection", .none, false),
        ]
        for (name, selection, on) in cases {
            model.timeline.selection = selection
            #expect(model.isOn(.duplicate) == on && app.isOn(.duplicate) == on, "\(name)")
        }

        model.timeline.selection = .range(range)
        #expect(model.clipboard == nil && model.isOn(.duplicate), "no clipboard")
        studio.transport = .recording(take: 1)
        #expect(!model.isOn(.duplicate), "a take")
        studio.transport = .idle
        model.importJob = ImportJob(visible: false)
        #expect(!model.isOn(.duplicate), "a paste run")
        model.importJob = nil
        #expect(model.isOn(.duplicate), "after the run")
        app.key = nil
        #expect(!app.isOn(.duplicate), "no session window")
        await model.close()
    }

    /// C17: after Duplicate the selection is the copy, so a second Duplicate puts a third copy after
    /// it, as a loop of the same audio. Each is one undo entry and one announcement, and the
    /// clipboard stays. A range case on t2, then a one-clip case on t1.
    @Test func duplicateTwiceMakesALoop() async throws {
        let (model, studio, _, _) = try await open()
        var heard: [String] = []
        model.chrome?.announce = { text, _ in heard.append(text) }
        model.timeline.marks = Marks(inPoint: 0, outPoint: 48_000, tracks: ["t1"])
        model.run(.copy)
        let clipboard = try #require(model.clipboard)
        let before = studio.session
        model.timeline.marks = Marks(inPoint: 96_000, outPoint: 144_000, tracks: ["t2"])

        model.run(.duplicate)
        #expect(model.timeline.selection == .range(Marks(inPoint: 144_000, outPoint: 192_000, tracks: ["t2"])))
        #expect(ranges(studio, "t2") == [0..<144_000, 144_000..<192_000, 192_000..<2_880_000])
        model.run(.duplicate)

        #expect(model.timeline.selection == .range(Marks(inPoint: 192_000, outPoint: 240_000, tracks: ["t2"])))
        #expect(ranges(studio, "t2") == [0..<144_000, 144_000..<192_000, 192_000..<240_000, 240_000..<2_880_000])
        let offsets = studio.session.track("t2")?.clips.map(\.offset)
        #expect(offsets == [0, 96_000, 96_000, 240_000], "both copies play the audio of the source")
        #expect(studio.session.track("t1") == before.track("t1") && model.clipboard == clipboard)
        #expect(heard == Array(repeating: L10n.duplicateDone.text, count: 2), "\(heard)")
        model.undo()
        model.undo()
        #expect(studio.session == before && !studio.canUndo, "one undo entry for each")

        model.timeline.selection = .clips(ClipSet("c1"))
        model.run(.duplicate)
        model.run(.duplicate)

        let loop = model.timeline.selection.selectedClips(in: studio.session).map(\.clip)
        #expect(loop.map(\.range) == [5_760_000..<8_640_000] && loop.map(\.offset) == [0] && loop.map(\.file) == ["f1"])
        #expect(ranges(studio, "t1") == [0..<2_880_000, 2_880_000..<5_760_000, 5_760_000..<8_640_000])
        #expect(heard.count == 4 && model.clipboard == clipboard)
        await model.close()
    }
}
