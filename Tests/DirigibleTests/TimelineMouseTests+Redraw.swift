import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Decision 0020, the dirty rect: the rects that a drag, an edit, and a new width redraw.
extension TimelineMouseTests {
    /// Decision 0020, the dirty rect: a drag event redraws only the columns of the clips that it
    /// changes, at full height (a narrow rect). c1 is x 200 to 300 pt; a drag of 50 pt makes it 250
    /// to 350, so the event redraws x 200 to 350 with 1 pt on each side, not the 1440 pt in view.
    /// New Marks draw their columns; new peaks draw all lanes in view. The next event draws only its own columns,
    /// x 249 to 361: the lanes are one layer of surfaces, so no image of the event before it stays
    /// (decision 0022).
    @Test func aDragEventRedrawsOnlyTheClipsItChanges() async throws {
        let (model, studio) = try await timelineModel(
            try await timelinePackage(in: folder.url, tracks: 2, seconds: 20), app: app)
        try studio.edit { s throws(SessionError) in try s.trim("c1", to: 102_400..<153_600) }
        let (window, view) = standaloneLanes(model, studio)
        try press(view, 250, 10)

        try drag(view, 300, 10)
        drawNow(window)

        #expect(view.lanes.drawnRect == NSRect(x: 199, y: 0, width: 152, height: 200))
        try drag(view, 310, 10)
        drawNow(window)
        #expect(view.lanes.drawnRect == NSRect(x: 249, y: 0, width: 112, height: 200), "only the event")
        view.update(laneInputs(model, studio, marks: Marks(inPoint: 0, outPoint: 512_000, tracks: ["t2"])))
        drawNow(window)
        #expect(view.lanes.drawnRect == NSRect(x: 0, y: 0, width: 1002, height: 200), "new Marks: all rows")
        view.update(laneInputs(model, studio, marks: Marks(inPoint: 0, outPoint: 512_000, tracks: ["t8"])))
        drawNow(window)
        let draws = view.lanes.draws
        view.update(laneInputs(model, studio, marks: Marks(inPoint: 0, outPoint: 512_000, tracks: ["t9"])))
        drawNow(window)
        #expect(view.lanes.draws == draws, "Marks that draw the same pixels draw nothing")
        var inputs = laneInputs(model, studio, marks: Marks(inPoint: 0, outPoint: 512_000, tracks: ["t9"]))
        inputs.peaks = ["f1": .ready(randomPeaks(frames: 960_000))]
        view.update(inputs)
        drawNow(window)
        #expect(view.lanes.drawnRect.width == 1440, "new peaks draw the lanes in view, not only the changed clips")
        window.close()
        await model.close()
    }

    /// Decision 0022: an edit far away (new Marks of x 400 to 800, drawn at x 399 to 802) adds
    /// nothing to the draws of a drag after it. c1 is x 200 to 300: the first event draws x 199 to
    /// 351, the next x 249 to 361. The timeline-scroll run drew the union of both, then all lanes.
    @Test func aDragAfterAnEditFarAwayDrawsOnlyTheEvents() async throws {
        let (model, studio) = try await timelineModel(
            try await timelinePackage(in: folder.url, tracks: 2, seconds: 20), app: app)
        try studio.edit { s throws(SessionError) in try s.trim("c1", to: 102_400..<153_600) }
        let (window, view) = standaloneLanes(model, studio)
        view.update(laneInputs(model, studio, marks: Marks(inPoint: 204_800, outPoint: 409_600, tracks: ["t1", "t2"])))
        drawNow(window)
        #expect(view.lanes.drawnRect == NSRect(x: 399, y: 0, width: 403, height: 200), "the Marks")
        try press(view, 250, 10)

        try drag(view, 300, 10)
        drawNow(window)
        #expect(view.lanes.drawnRect == NSRect(x: 199, y: 0, width: 152, height: 200), "the first event")
        try drag(view, 310, 10)
        drawNow(window)
        #expect(view.lanes.drawnRect == NSRect(x: 249, y: 0, width: 112, height: 200), "only the event")

        try release(view, 310, 10)
        window.close()
        await model.close()
    }

    /// Decision 0022: a draw covers only the whole lanes in view. 8 lanes of 100 pt, 376 pt in
    /// view (lanes 1 to 4): new Marks of x 400 to 600 draw x 399 to 602 on the lanes in view, and
    /// the first event of a drag of c1 (x 200 to 300) draws x 199 to 351 on them, not on all 8.
    @Test func aDrawCoversOnlyTheLanesInView() async throws {
        let (model, studio) = try await timelineModel(
            try await timelinePackage(in: folder.url, tracks: 8, seconds: 20), app: app)
        try studio.edit { s throws(SessionError) in try s.trim("c1", to: 102_400..<153_600) }
        let (window, view) = standaloneLanes(model, studio)
        try #require(view.shown.minY == 0 && view.shown.height == 376, "\(view.shown)")
        let all = Set((1...8).map { TrackID("t\($0)") })
        view.update(laneInputs(model, studio, marks: Marks(inPoint: 204_800, outPoint: 307_200, tracks: all)))
        drawNow(window)
        #expect(view.lanes.drawnRect == NSRect(x: 399, y: 0, width: 203, height: 400), "the Marks")
        try press(view, 250, 10)

        try drag(view, 300, 10)
        drawNow(window)

        #expect(view.lanes.drawnRect == NSRect(x: 199, y: 0, width: 152, height: 400), "the event")
        try release(view, 300, 10)
        window.close()
        await model.close()
    }

    /// Code gate 1 item 2: a drag of a clip wider than the view redraws the rows of its lanes only.
    /// c1 is x 0 to 1875 pt on lane 1 of 3; a drag to lane 2 redraws the rows of lanes 1 and 2.
    @Test func aWideClipDragRedrawsOnlyTheRowsOfItsLanes() async throws {
        let (model, _, window, view) = try await lanes(tracks: 3)
        try press(view, 100, 10)

        try drag(view, 150, 10)
        drawNow(window)
        #expect(view.lanes.drawnRect.minY == 0 && view.lanes.drawnRect.height == 100, "lane 1")
        try drag(view, 150, 110)
        drawNow(window)
        #expect(view.lanes.drawnRect.minY == 0 && view.lanes.drawnRect.height == 200, "lanes 1 and 2")

        try release(view, 100, 10)
        window.close()
        await model.close()
    }

    /// Code gate 1 item 2: during a move of the last clip past the session end, the lanes keep
    /// their width, so the event redraws only the columns of the clip (AppKit draws the new columns
    /// of a wider view, and the draw joins them). The part past the lanes is never in view: the lanes
    /// are at least as wide as the view. The mouse-up gives the new width. c1 is x 1800 to 1875 pt,
    /// the end of the session; the lanes in view end at the end of the lanes (1912.5 pt).
    @Test func aDragPastTheEndKeepsTheWidthUntilTheUp() async throws {
        let (model, studio) = try await timelineModel(
            try await timelinePackage(in: folder.url, tracks: 2, seconds: 20), app: app)
        try studio.edit { s throws(SessionError) in
            try s.trim("c1", to: 921_600..<960_000)
            try s.trim("c2", to: 0..<102_400)
        }
        let (window, view) = standaloneLanes(model, studio)
        view.scroll(toFrame: 472.5 * 512)
        drawNow(window)
        let width = view.lanes.frame.width
        try press(view, 1830, 10)

        try drag(view, 1880, 10)
        drawNow(window)

        #expect(view.lanes.frame.width == width, "the same width during the drag")
        #expect(view.lanes.drawnRect == NSRect(x: 1799, y: 0, width: 113.5, height: 200), "not the new columns")
        try release(view, 1880, 10)
        #expect(view.lanes.frame.width == width + 50 * 1.02, "the new width at the up")
        window.close()
        await model.close()
    }

    /// Phase 7 of the mouse-edits run: a new width redraws the lanes in view. With the redraw
    /// policy `onSetNeedsDisplay`, AppKit drew only the new columns, and on screen the old columns
    /// showed the old pixels scaled to the new width (a strip of stripes at the left after a move
    /// past the session end). At 2048 frames per point the lanes are as wide as the view (1440 pt);
    /// a view 160 pt wider makes them 1600 pt wide.
    @Test func aNewWidthRedrawsTheLanesInView() async throws {
        let (model, studio, window, view) = try await lanes()
        var inputs = laneInputs(model, studio)
        inputs.scale = TimelineScale(framesPerPoint: 2048)
        view.update(inputs)
        drawNow(window)
        #expect(view.lanes.frame.width == 1440)
        let draws = view.lanes.draws

        window.setContentSize(NSSize(width: window.frame.width + 160, height: window.frame.height))
        view.frame = try #require(window.contentView).bounds
        drawNow(window)

        #expect(view.lanes.frame.width == 1600)
        #expect(view.lanes.draws == draws + 1, "one draw")
        #expect(view.lanes.drawnRect.minX == 0 && view.lanes.drawnRect.width >= 1600, "\(view.lanes.drawnRect)")
        window.close()
        await model.close()
    }
}
