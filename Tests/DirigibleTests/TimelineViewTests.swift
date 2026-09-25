import AppKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The timeline in a real session window (decision 0017, timeline-view criteria 16 and 19).
@Suite(.serialized) @MainActor struct TimelineViewTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws { folder = try TemporaryFolder() }

    /// Criterion 19: the transport bar warns only for an armed clip at the playhead that is not in
    /// view. Controls: an armed lane in view does not warn; nothing is in view before a layout.
    @Test func theRecordOverWarningNeedsAnArmedClipOutOfView() async throws {
        let (window, studio) = try await timelineModel(
            try await timelinePackage(in: folder.url, tracks: 8, seconds: 20), app: app)
        await studio.perform(.seek(.frame(100_000)))
        let visible = TimelineVisible(frames: 0..<737_280, lanes: 0..<5)

        window.armed = ["t7"]
        window.timeline.visible = nil
        #expect(window.showsRecordOver, "before the first layout")
        window.timeline.visible = visible
        #expect(window.showsRecordOver, "lane 7 is under the visible lanes")

        window.armed = ["t2"]
        #expect(!window.showsRecordOver, "lane 2 is in view")
        window.timeline.visible = TimelineVisible(frames: 200_000..<937_280, lanes: 0..<5)
        #expect(window.showsRecordOver, "the playhead is before the visible frames")
        await window.close()
    }

    /// A mouse event at the document point `point` of the lanes.
    func mouse(
        _ type: NSEvent.EventType, _ point: NSPoint, in view: TimelineScrollView, flags: NSEvent.ModifierFlags = []
    )
        throws -> NSEvent
    {
        try #require(
            NSEvent.mouseEvent(
                with: type, location: view.lanes.convert(point, to: nil), modifierFlags: flags, timestamp: 0,
                windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    /// Criterion 16: a click at x = 200 pt on lane 2 seeks to 102,400 (± one point of frames) and
    /// empties the Marks; a Command-click selects the lane under the pointer.
    @Test func aClickInALaneSeeksThePlayheadAndEmptiesTheMarks() async throws {
        let (model, studio) = try await timelineModel(
            try await timelinePackage(in: folder.url, tracks: 2, seconds: 20), app: app)
        let (lanesWindow, view) = standaloneLanes(model, studio)
        model.timeline.marks = Marks(inPoint: 0, outPoint: 1000, tracks: ["t1"])

        view.lanes.mouseDown(with: try mouse(.leftMouseDown, NSPoint(x: 200, y: 150), in: view))
        view.lanes.mouseDragged(with: try mouse(.leftMouseDragged, NSPoint(x: 201, y: 151), in: view))
        view.lanes.mouseUp(with: try mouse(.leftMouseUp, NSPoint(x: 201, y: 151), in: view))

        #expect(model.timeline.marks == Marks())
        await until("the click seeks") { abs(studio.playhead.count - 102_400) <= 512 }
        view.lanes.mouseDown(with: try mouse(.leftMouseDown, NSPoint(x: 300, y: 150), in: view, flags: .command))
        view.lanes.mouseUp(with: try mouse(.leftMouseUp, NSPoint(x: 300, y: 150), in: view, flags: .command))
        #expect(model.timeline.marks.tracks == ["t2"])
        lanesWindow.close()
        await model.close()
    }

    /// Criterion 16: a drag of 10 pt in lane 2 selects its range on lane 2; a drag from lane 1
    /// to lane 2 selects both.
    @Test func aDragMakesTheMarksOnTheLanesItSpans() async throws {
        let (model, studio) = try await timelineModel(
            try await timelinePackage(in: folder.url, tracks: 3, seconds: 20), app: app)
        let (lanesWindow, view) = standaloneLanes(model, studio)

        view.lanes.mouseDown(with: try mouse(.leftMouseDown, NSPoint(x: 100, y: 150), in: view))
        view.lanes.mouseDragged(with: try mouse(.leftMouseDragged, NSPoint(x: 105, y: 150), in: view))
        view.lanes.mouseUp(with: try mouse(.leftMouseUp, NSPoint(x: 110, y: 150), in: view))
        #expect(model.timeline.marks == Marks(inPoint: 51_200, outPoint: 56_320, tracks: ["t2"]))

        view.lanes.mouseDown(with: try mouse(.leftMouseDown, NSPoint(x: 300, y: 50), in: view))
        view.lanes.mouseDragged(with: try mouse(.leftMouseDragged, NSPoint(x: 200, y: 150), in: view))
        view.lanes.mouseUp(with: try mouse(.leftMouseUp, NSPoint(x: 200, y: 150), in: view))
        #expect(model.timeline.marks == Marks(inPoint: 102_400, outPoint: 153_600, tracks: ["t1", "t2"]))
        #expect(studio.playhead == studio.session.end, "a drag does not seek")
        lanesWindow.close()
        await model.close()
    }

    /// Criterion 16: a clip box is at start / framesPerPoint, length / framesPerPoint wide, in
    /// the lane of its track.
    @Test func aClipBoxIsAtItsStartOverTheScale() async throws {
        let (model, studio) = try await timelineModel(
            try await timelinePackage(in: folder.url, tracks: 2, seconds: 20), app: app)
        try studio.edit { s throws(SessionError) in try s.move("c2", to: "t2", start: 48_000) }
        let (lanesWindow, view) = standaloneLanes(model, studio)

        #expect(view.lanes.clipFrame("c2") == NSRect(x: 93.75, y: 100, width: 1875, height: 100))
        #expect(view.lanes.clipFrame("c1") == NSRect(x: 0, y: 0, width: 1875, height: 100))
        lanesWindow.close()
        await model.close()
    }

    /// A click on the ruler seeks and keeps the Marks.
    @Test func aRulerClickSeeksAndKeepsTheMarks() async throws {
        let (model, studio) = try await timelineModel(
            try await timelinePackage(in: folder.url, tracks: 2, seconds: 20), app: app)
        let (lanesWindow, view) = standaloneLanes(model, studio)
        let marks = Marks(inPoint: 0, outPoint: 1000, tracks: ["t1"])
        model.timeline.marks = marks

        view.ruler.mouseDown(with: try mouse(.leftMouseDown, NSPoint(x: 400, y: 0), in: view))

        await until("the ruler click seeks") { abs(studio.playhead.count - 204_800) <= 512 }
        #expect(model.timeline.marks == marks)
        lanesWindow.close()
        await model.close()
    }

    /// Criterion 19 in a real window: 8 tracks and a height for fewer lanes. An armed lane 7
    /// with a clip under the playhead warns; an armed lane 2 does not.
    @Test func aClippedArmedLaneShowsTheWarning() async throws {
        let window = await app.open(try await timelinePackage(in: folder.url, tracks: 8, seconds: 20))
        let studio = try #require(await window.opened() ? window.studio : nil)
        window.window?.setContentSize(NSSize(width: 1000, height: 360))
        await until("the lanes publish what is in view") { window.timeline.visible != nil }
        await studio.perform(.seek(.frame(100_000)))
        let visible = try #require(window.timeline.visible)
        #expect(!visible.lanes.contains(6) && visible.frames.contains(100_000), "\(visible)")

        window.armed = ["t7"]
        #expect(window.showsRecordOver)
        window.armed = ["t2"]
        #expect(!window.showsRecordOver)
        await window.close()
    }

    /// The display link ends with the window: its target goes, and it ticks while it runs.
    @Test func theDisplayLinkEndsWithTheWindow() async throws {
        let (model, studio) = try await timelineModel(
            try await timelinePackage(in: folder.url, tracks: 1, seconds: 20), app: app)
        let (lanesWindow, view) = standaloneLanes(model, studio, onScreen: true)
        weak var proxy = view.linkProxy
        await until("the display link ticks twice") { (proxy?.ticks ?? 0) >= 2 }

        view.removeFromSuperview()

        await until("the display link target goes") { proxy == nil }
        lanesWindow.close()
        await model.close()
    }

    @Test func aRulerLabelShowsMinutesSecondsAndTenths() {
        #expect(rulerLabel(65, tenths: false) == "1:05")
        #expect(rulerLabel(3725.5, tenths: true) == "1:02:05.5")
        #expect(rulerLabel(0.1, tenths: true) == "0:00.1")
    }
}
