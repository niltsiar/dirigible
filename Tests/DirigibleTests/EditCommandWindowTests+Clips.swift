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

    /// C11a, C11e, C11f, C11g, C12. Controls: a hull Delete removes c1@48000; a Copy of the hull
    /// fills the clipboard.
    @Test func eachEditOnAClipSelection() async throws {
        let (model, studio, _, _) = try await openSet()
        var beeps = 0
        model.beep = { beeps += 1 }
        let before = studio.session
        for command in [TimelineCommand.copy, .cut, .deleteCloseGap, .cutSelectedTracks, .deleteCloseGapSelectedTracks]
        {
            model.run(command)
        }
        #expect(beeps == 5 && studio.session == before && model.clipboard == nil, "beeps \(beeps)")
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
}
