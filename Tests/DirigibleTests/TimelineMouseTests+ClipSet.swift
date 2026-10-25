import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// C15 and C17 of run 2026-10-16-timeline-clarity: a plain click on a clip selects it as a clip set
/// (decision 0038), so the commands that need a range or a header track are off or act on the clip.
extension TimelineMouseTests {
    /// A click on the upper part of c1 (the move zone), with the model and the lanes of `lanes()`.
    func clickC1() async throws -> (SessionWindow, Studio, NSWindow, TimelineScrollView) {
        let opened = try await lanes()
        try press(opened.3, 100, 10)
        try release(opened.3, 101, 10)
        await settle()
        #expect(opened.0.timeline.selection == .clips(ClipSet("c1")), "the click selected no clip set")
        return opened
    }

    @Test func aClickOnAClipShowsNoInOrOutMarker() async throws {
        let (model, studio, window, view) = try await clickC1()

        view.update(laneInputs(model, studio, selection: model.timeline.selection))

        #expect(view.ruler.inputs?.marks == Marks(), "the ruler draws a triangle")
        window.close()
        await model.close()
    }

    @Test func deleteAndCloseGapAfterAClipClickBeeps() async throws {
        let (model, studio, window, _) = try await clickC1()
        let before = studio.session
        var beeps = 0
        model.beep = { beeps += 1 }

        model.run(.deleteCloseGap)

        #expect(beeps == 1 && studio.session == before && !studio.canUndo, "beeps \(beeps)")
        window.close()
        await model.close()
    }

    /// Control: a ripple Cut of the range of c1 closes the gap on both tracks and removes c2 too.
    @Test func cutAfterAClipClickLeavesTheGap() async throws {
        let (model, studio, window, _) = try await clickC1()

        model.run(.cut)

        #expect(studio.session.track("t1")?.clips.isEmpty == true, "c1 stays")
        #expect(studio.session.track("t2")?.clips.map(\.id) == ["c2"], "the cut changed t2")
        window.close()
        await model.close()
    }

    @Test func exportSelectionIsOffAfterAClipClick() async throws {
        let (model, _, window, _) = try await clickC1()

        #expect(!model.canExportSelection && !model.isOn(.exportSelection))
        window.close()
        await model.close()
    }

    @Test func healAndPlaceAtPlayheadAreOffAfterAClipClick() async throws {
        let (model, _, window, _) = try await clickC1()

        #expect(!model.isOn(.heal), "Heal Clips is on")
        #expect(!model.canPlaceAtPlayhead, "Place at Playhead is on")
        window.close()
        await model.close()
    }
}
