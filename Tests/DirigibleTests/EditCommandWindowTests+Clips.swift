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
        try opened.1.edit { session throws(SessionError) in _ = try session.split("c1", at: 48_000) }
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
        #expect(studio.session == before && model.alert == .error(.session(.trackCount(2))), "C8d")
        #expect(model.clipboard == excerpt)
        model.alert = nil

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
}
