import AppKit
import DirigibleCore
import DirigibleTimeline
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

    /// A session window of `tracks` tracks at its default size, after SwiftUI shows the lanes.
    func openWindow(tracks: Int) async throws -> (SessionWindow, Studio, TimelineScrollView) {
        let window = await app.open(try await timelinePackage(in: folder.url, tracks: tracks, seconds: 20))
        let studio = try #require(await window.opened() ? window.studio : nil)
        await until("the window shows the lanes") {
            window.timelineView?.window != nil && window.timeline.visible != nil
        }
        return (window, studio, try #require(window.timelineView))
    }

    /// The name field of the track header that shows `name`.
    func nameField(_ name: String, in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable, field.stringValue == name { return field }
        return view.subviews.lazy.compactMap { self.nameField(name, in: $0) }.first
    }

    /// Code gate 1 item 1: 7 tracks do not fit the default window. After a vertical scroll to
    /// each lane, the header of its track (the name field, on the line of the arm toggle) is
    /// beside the lane and in view. A wheel over a header scrolls the lanes and the headers.
    @Test func eachTrackHeaderScrollsWithItsLane() async throws {
        let (window, _, view) = try await openWindow(tracks: 7)
        let content = try #require(window.window?.contentView)
        let height = try #require(view.lanes.inputs).laneHeight
        #expect(view.lanes.frame.height > view.shown.height, "7 lanes fit the default window")

        for lane in 0..<7 {
            view.lanes.scrollToVisible(
                NSRect(x: view.shown.minX, y: Double(lane) * height, width: 1, height: height))
            content.layoutSubtreeIfNeeded()
            let field = try #require(nameField("T\(lane + 1)", in: content))
            let row = field.convert(field.bounds, to: nil)
            let box = view.lanes.convert(NSRect(x: 0, y: Double(lane) * height, width: 1, height: height), to: nil)
            let shown = view.lanes.convert(view.shown, to: nil)
            #expect(box.minY <= row.minY && row.maxY <= box.maxY, "the header of lane \(lane + 1) is beside it")
            #expect(shown.minY <= row.minY && row.maxY <= shown.maxY, "the header of lane \(lane + 1) is in view")
        }

        let bottom = view.contentView.bounds.minY
        let wheel = try #require(
            CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 5, wheel2: 0, wheel3: 0)
                .flatMap { NSEvent(cgEvent: $0) })
        try #require(nameField("T7", in: content)).scrollWheel(with: wheel)
        // The scroll view animates a wheel scroll.
        await until("a wheel over the headers scrolls up") { view.contentView.bounds.minY < bottom }
        await window.close()
    }

    /// Code gate 1 item 1: a new window with more lanes than fit shows the top of lane 1 and
    /// frame 0 at the top left of the lanes in view, not under the rulers. The clip view gets the
    /// ruler insets after the first fit.
    @Test func aNewWindowShowsTheStartOfLaneOne() async throws {
        let (window, _, view) = try await openWindow(tracks: 7)

        #expect(view.shown.minY == 0 && view.shown.minX == 0, "\(view.shown)")
        await window.close()
    }

    /// Code gate 1 item 1: the record-over warning reads the lanes in view after a vertical
    /// scroll, and a zoom (a page turn) keeps the vertical origin.
    @Test func theWarningSeesAnArmedLaneScrolledAboveTheView() async throws {
        let (window, studio, view) = try await openWindow(tracks: 7)
        await studio.perform(.seek(.frame(100_000)))
        window.armed = ["t1"]
        let insets = view.contentView.contentInsets
        view.contentView.scroll(to: NSPoint(x: view.contentView.bounds.minX, y: 10 - insets.top))
        view.reflectScrolledClipView(view.contentView)
        #expect(window.showsRecordOver, "the top 10 pt of lane 1 are under the time ruler")

        view.lanes.scrollToVisible(
            NSRect(x: view.shown.minX, y: view.lanes.frame.height - 1, width: 1, height: 1))
        let top = view.contentView.bounds.minY
        #expect(view.shown.minY > 10, "the lanes scroll down")
        #expect(window.showsRecordOver, "lane 1 is above the view")
        window.armed = ["t7"]
        #expect(!window.showsRecordOver, "lane 7 is in view")
        window.run(.zoomIn)
        #expect(view.contentView.bounds.minY == top, "a zoom keeps the vertical origin")
        await window.close()
    }

    /// Code gate 1 item 3: the label of a clip draws at the bottom left of its box, in the lane
    /// of its track, and not in another lane.
    @Test func aClipLabelDrawsInTheLaneOfItsTrack() throws {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f1", path: "take1-1-1.wav", layout: .mono, length: 480_000))
        try session.addTrack("t1", name: "T1", layout: .mono)
        try session.addTrack("t2", name: "T2", layout: .mono)
        try session.place(Clip(id: "c1", file: "f1", start: 48_000, offset: 0, length: 432_000), on: "t2")
        let view = documentView(session)

        // The box of c1 starts at 93.75 pt; lane 2 is 100 to 200 pt.
        #expect(try darkPixels(view, in: NSRect(x: 90, y: 184, width: 60, height: 16)) > 20, "the label in lane 2")
        #expect(try darkPixels(view, in: NSRect(x: 90, y: 84, width: 60, height: 16)) == 0, "no label in lane 1")
        #expect(try darkPixels(view, in: NSRect(x: 0, y: 184, width: 90, height: 16)) == 0, "no label before c1")
    }

    /// Mouse-edits criterion 17: a clip label draws only in a box of 60 pt or more (probe L1:
    /// 12,000 labels at fit zoom take 330 ms per draw). At 512 frames per point, c1 is 59 pt
    /// wide from x 0, and c2 is 60 pt wide from x 100.
    @Test func aClipLabelDrawsOnlyInABoxOfSixtyPoints() throws {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f1", path: "take1-1-1.wav", layout: .mono, length: 480_000))
        try session.addTrack("t1", name: "T1", layout: .mono)
        try session.place(Clip(id: "c1", file: "f1", start: 0, offset: 0, length: 30_208), on: "t1")
        try session.place(Clip(id: "c2", file: "f1", start: 51_200, offset: 0, length: 30_720), on: "t1")
        let view = documentView(session)

        #expect(try darkPixels(view, in: NSRect(x: 0, y: 84, width: 59, height: 16)) == 0, "no label in 59 pt")
        #expect(try darkPixels(view, in: NSRect(x: 100, y: 84, width: 60, height: 16)) > 20, "a label in 60 pt")
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
