import AppKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio
@testable import DirigibleTimeline

/// The timeline in a real session window (decision 0017, timeline-view criteria 16 and 19).
@Suite(.serialized) @MainActor struct TimelineViewTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws { folder = try TemporaryFolder() }

    /// Criterion 19: the record-over overlay shows only when Record can reach a clip on an armed
    /// track that is not in view. Controls: an armed lane in view does not warn; nothing is in view
    /// before a layout.
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

    /// Criterion 16: a click at x = 200 pt on lane 2 seeks to 102,400 (± one point of frames) and
    /// empties the Marks; a Command-click selects the lane under the pointer. The plain click is in
    /// the lower third of the clip (the range zone): a click on the upper part selects the clip
    /// (mouse-edits criterion 2). The Command-click is in the lower third too: on the upper part it
    /// toggles the clip (decision 0038).
    @Test func aClickInALaneSeeksThePlayheadAndEmptiesTheMarks() async throws {
        let (model, studio) = try await timelineModel(
            try await timelinePackage(in: folder.url, tracks: 2, seconds: 20), app: app)
        let (lanesWindow, view) = standaloneLanes(model, studio)
        model.timeline.marks = Marks(inPoint: 0, outPoint: 1000, tracks: ["t1"])

        view.lanes.mouseDown(with: try mouse(.leftMouseDown, NSPoint(x: 200, y: 180), in: view))
        view.lanes.mouseDragged(with: try mouse(.leftMouseDragged, NSPoint(x: 201, y: 181), in: view))
        view.lanes.mouseUp(with: try mouse(.leftMouseUp, NSPoint(x: 201, y: 181), in: view))

        #expect(model.timeline.marks == Marks())
        await until("the click seeks") { abs(studio.playhead.count - 102_400) <= 512 }
        view.lanes.mouseDown(with: try mouse(.leftMouseDown, NSPoint(x: 300, y: 180), in: view, flags: .command))
        view.lanes.mouseUp(with: try mouse(.leftMouseUp, NSPoint(x: 300, y: 180), in: view, flags: .command))
        #expect(model.timeline.marks?.tracks == ["t2"])
        lanesWindow.close()
        await model.close()
    }

    /// Criterion 16: a drag of 10 pt in lane 2 selects its range on lane 2; a drag from lane 1
    /// to lane 2 selects both. Each drag starts in the lower third of a clip (the range zone).
    @Test func aDragMakesTheMarksOnTheLanesItSpans() async throws {
        let (model, studio) = try await timelineModel(
            try await timelinePackage(in: folder.url, tracks: 3, seconds: 20), app: app)
        let (lanesWindow, view) = standaloneLanes(model, studio)

        view.lanes.mouseDown(with: try mouse(.leftMouseDown, NSPoint(x: 100, y: 180), in: view))
        view.lanes.mouseDragged(with: try mouse(.leftMouseDragged, NSPoint(x: 105, y: 180), in: view))
        view.lanes.mouseUp(with: try mouse(.leftMouseUp, NSPoint(x: 110, y: 180), in: view))
        #expect(model.timeline.marks == Marks(inPoint: 51_200, outPoint: 56_320, tracks: ["t2"]))

        view.lanes.mouseDown(with: try mouse(.leftMouseDown, NSPoint(x: 300, y: 90), in: view))
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
        try studio.edit(ripple: false) { s throws(SessionError) in try s.move("c2", to: "t2", start: 48_000) }
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

    /// Criterion 19 in a real window: 12 tracks and a height for fewer lanes (the minimum, 360 pt,
    /// gives 8 lanes of 40 pt). An armed lane 12 with a clip under the playhead warns; an armed
    /// lane 2 does not.
    @Test func aClippedArmedLaneShowsTheWarning() async throws {
        let window = await app.open(try await timelinePackage(in: folder.url, tracks: 12, seconds: 20))
        let studio = try #require(await window.opened() ? window.studio : nil)
        try await fixFreeSpace(window)
        window.window?.setContentSize(NSSize(width: 1000, height: 360))
        await until("the lanes publish the smaller height") {
            window.timeline.visible.map { !$0.lanes.contains(11) } == true
        }
        await studio.perform(.seek(.frame(100_000)))
        let visible = try #require(window.timeline.visible)
        #expect(!visible.lanes.contains(11) && visible.frames.contains(100_000), "\(visible)")

        window.armed = ["t12"]
        #expect(window.showsRecordOver)
        window.armed = ["t2"]
        #expect(!window.showsRecordOver)
        await window.close()
    }

    /// A session window of `tracks` tracks at its default size, after SwiftUI shows the lanes.
    func openWindow(tracks: Int) async throws -> (SessionWindow, Studio, TimelineScrollView) {
        let window = await app.open(try await timelinePackage(in: folder.url, tracks: tracks, seconds: 20))
        let studio = try #require(await window.opened() ? window.studio : nil)
        try await fixFreeSpace(window)
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

    /// More tracks than fit the default window of 720 pt: 20 lanes of at least 40 pt.
    static let tracksThatDoNotFit = 20

    /// Code gate 1 item 1: the tracks do not fit the default window. After a vertical scroll to
    /// each lane, the header of its track (the name field, on the line of the arm toggle) is
    /// beside the lane and in view. A wheel over a header goes to the scroll view of the lanes
    /// and starts its live scroll; the headers are its vertical ruler, so they scroll with the lanes.
    @Test func eachTrackHeaderScrollsWithItsLane() async throws {
        let (window, _, view) = try await openWindow(tracks: Self.tracksThatDoNotFit)
        let content = try #require(window.window?.contentView)
        let height = try #require(view.lanes.inputs).laneHeight
        #expect(view.lanes.frame.height > view.shown.height, "the lanes fit the default window")

        for lane in 0..<Self.tracksThatDoNotFit {
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

        // The wheel goes to the scroll view of the lanes, which starts a live scroll at once. The
        // scroll itself is an AppKit step after the call: in a loaded suite with about 20 windows,
        // that step did not come in 60 s (run wait-limits), so the test does not wait for it.
        #expect(view.liveScrollOrigin == nil)
        let wheel = try #require(
            CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 5, wheel2: 0, wheel3: 0)
                .flatMap { NSEvent(cgEvent: $0) })
        try #require(nameField("T\(Self.tracksThatDoNotFit)", in: content)).scrollWheel(with: wheel)
        #expect(view.liveScrollOrigin != nil, "a wheel over the headers scrolls the lanes")
        await window.close()
    }

    /// The lanes follow the system setting "Show scroll bars" (the preferred scroller style), as
    /// other Mac apps do: the user asked for no scroll bar at all times (timeline-scroll Q3). On a
    /// Mac whose preferred style is legacy, a forced legacy style cannot fail this test.
    @Test func theLanesFollowTheSystemScrollerStyle() async throws {
        let (window, _, view) = try await openWindow(tracks: 3)
        for _ in 0..<4 { window.run(.zoomIn) }
        view.layoutSubtreeIfNeeded()
        let scroller = try #require(view.horizontalScroller)

        #expect(view.scrollerStyle == NSScroller.preferredScrollerStyle, "style \(view.scrollerStyle.rawValue)")
        #expect(scroller.knobProportion < 1, "the zoom makes the lanes wider than the view")
        await window.close()
    }

    /// Code gate 1 item 1: a new window with more lanes than fit shows the top of lane 1 and
    /// frame 0 at the top left of the lanes in view, not under the rulers. The clip view gets the
    /// ruler insets after the first fit.
    @Test func aNewWindowShowsTheStartOfLaneOne() async throws {
        let (window, _, view) = try await openWindow(tracks: Self.tracksThatDoNotFit)

        #expect(view.shown.minY == 0 && view.shown.minX == 0, "\(view.shown)")
        await window.close()
    }

    /// Code gate 1 item 1: the record-over warning reads the lanes in view after a vertical
    /// scroll, and a zoom (a page turn) keeps the vertical origin.
    @Test func theWarningSeesAnArmedLaneScrolledAboveTheView() async throws {
        let (window, studio, view) = try await openWindow(tracks: Self.tracksThatDoNotFit)
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
        window.armed = [TrackID("t\(Self.tracksThatDoNotFit)")]
        #expect(!window.showsRecordOver, "the last lane is in view")
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
        let (window, view) = documentView(session)
        defer { window.close() }

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
        let (window, view) = documentView(session)
        defer { window.close() }

        #expect(try darkPixels(view, in: NSRect(x: 0, y: 84, width: 59, height: 16)) == 0, "no label in 59 pt")
        #expect(try darkPixels(view, in: NSRect(x: 100, y: 84, width: 60, height: 16)) > 20, "a label in 60 pt")
    }

    /// A label draws only inside its box, so the dirty rect of a drag event (the columns of the
    /// changed clips) holds every label that the event changes. c1 is 60 pt wide from x 0 with a
    /// name of about 200 pt: a draw of the box and the gap after it has no more label pixels than
    /// a draw of the box. (A draw of the gap alone does not draw c1.)
    @Test func aClipLabelStaysInItsBox() throws {
        var session = Session(sampleRate: 48_000)
        try session.addFile(
            AudioFile(id: "f1", path: "a-long-take-name-for-the-guest-interview.wav", layout: .mono, length: 480_000))
        try session.addTrack("t1", name: "T1", layout: .mono)
        try session.place(Clip(id: "c1", file: "f1", start: 0, offset: 0, length: 30_720), on: "t1")
        let (window, view) = documentView(session)
        defer { window.close() }

        let box = try darkPixels(view, in: NSRect(x: 0, y: 84, width: 60, height: 16))
        #expect(box > 20, "a label in the box")
        #expect(try darkPixels(view, in: NSRect(x: 0, y: 84, width: 260, height: 16)) == box, "no label after it")
    }

    /// Mouse-edits code gate 1 item 2: a draw of some lanes (the dirty rect of a drag event on
    /// one lane) puts their pixels in their rows. c1 is on lane 2 from x 0 to 93.75 pt; lane 1 is
    /// empty. In a window, so row 0 of the surface shows at the top of the flipped lanes.
    @Test func aDrawOfSomeLanesPutsTheirPixelsInTheirRows() throws {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f1", path: "f1.wav", layout: .mono, length: 480_000))
        try session.addTrack("t1", name: "T1", layout: .mono)
        try session.addTrack("t2", name: "T2", layout: .mono)
        try session.place(Clip(id: "c1", file: "f1", start: 0, offset: 0, length: 48_000), on: "t2")
        let (window, view) = documentView(session)
        defer { window.close() }

        #expect(try isClip(view, at: NSPoint(x: 20, y: 150), drawing: NSRect(x: 0, y: 100, width: 50, height: 100)))
        #expect(try !isClip(view, at: NSPoint(x: 20, y: 50), drawing: NSRect(x: 0, y: 0, width: 50, height: 100)))
        let both = NSRect(x: 0, y: 50, width: 50, height: 100)
        #expect(try isClip(view, at: NSPoint(x: 20, y: 140), drawing: both), "lane 2 of a draw of two lanes")
        #expect(try !isClip(view, at: NSPoint(x: 20, y: 60), drawing: both), "lane 1 of a draw of two lanes")
    }

    /// True when a draw of `rect` of `view` has the clip color at `point`, not the lane color. The
    /// snapshot converts the colors of a layer (an sRGB image or surface showed the clip red as 209,
    /// not 196), so the test takes the midpoint of the clip and lane reds.
    func isClip(_ view: NSView, at point: NSPoint, drawing rect: NSRect) throws -> Bool {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: rect))
        view.cacheDisplay(in: rect, to: bitmap)
        let scale = Double(bitmap.pixelsWide) / rect.width
        let color = try #require(
            bitmap.colorAt(x: Int((point.x - rect.minX) * scale), y: Int((point.y - rect.minY) * scale))?
                .usingColorSpace(.sRGB))
        // The clip color is 0xC4DAF5, the lane color 0xE8ECF2.
        return color.redComponent < (0xC4 + 0xE8) / 2 / 255
    }

    /// Mouse-edits criterion 1 (plan gate 2 item 4): the renderer draws a clip where the hit test
    /// finds it. At 512 frames per point and scale 2, the box of c2 on lane 2 is x 93.75 to
    /// 281.25 pt, so its edges are half pixels (187.5 and 562.5 px). 1 px inside each edge is the
    /// clip color, 1 px outside is the lane color, and the hit test agrees 0.5 pt from each edge.
    @Test func aClipBoxDrawsWhereTheHitTestFindsIt() throws {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f1", path: "f1.wav", layout: .mono, length: 480_000))
        for n in 1...3 { try session.addTrack(TrackID("t\(n)"), name: "T\(n)", layout: .mono) }
        let clip = Clip(id: "c2", file: "f1", start: 48_000, offset: 0, length: 96_000)
        try session.place(clip, on: "t2")
        let inputs = LaneInputs(
            session: session, peaks: [:], missingMedia: [:], selection: .none,
            scale: TimelineScale(framesPerPoint: 512),
            laneHeight: 100)
        let geometry = try #require(LaneGeometry(scale: inputs.scale, laneHeight: inputs.laneHeight))
        let box = geometry.box(of: clip, lane: 1)
        let pixels = OwnedPixels(try #require(laneWindow(inputs, width: 300, scale: 2)))

        pixels.draw { LaneRenderer().draw(inputs, .light, into: $0) }

        let (left, right, top, bottom) = (box.minX * 2, box.maxX * 2, Int(box.minY * 2), Int(box.maxY * 2))
        #expect((left, right) == (187.5, 562.5))
        #expect(pixels.pixel(Int(left + 1), 300) == LanePalette.light.clip, "1 px inside the left edge")
        #expect(pixels.pixel(Int(left - 1), 300) == LanePalette.light.lane, "1 px outside the left edge")
        #expect(pixels.pixel(Int(right - 1), 300) == LanePalette.light.clip, "1 px inside the right edge")
        #expect(pixels.pixel(Int(right + 1), 300) == LanePalette.light.lane, "1 px outside the right edge")
        #expect(
            pixels.pixel(300, top + 1) == LanePalette.light.clip && pixels.pixel(300, top - 1) == LanePalette.light.lane
        )
        #expect(
            pixels.pixel(300, bottom - 1) == LanePalette.light.clip
                && pixels.pixel(300, bottom + 1) == LanePalette.light.lane)
        let middle = box.minY + 10
        #expect(geometry.hit(box.minX + 0.5, middle, in: session) == .trim(clip, .start, lane: 1))
        #expect(geometry.hit(box.minX - 0.5, middle, in: session) == .range(lane: 1))
        #expect(geometry.hit(box.maxX - 0.5, middle, in: session) == .trim(clip, .end, lane: 1))
        #expect(geometry.hit(box.maxX + 0.5, middle, in: session) == .range(lane: 1))
        #expect(geometry.hit(150, box.minY - 0.5, in: session) == .range(lane: 0))
        #expect(geometry.hit(150, box.maxY + 0.5, in: session) == .range(lane: 2))
    }

    /// The display link ends with the window: its target goes, and it ticks while it runs.
    @Test func theDisplayLinkEndsWithTheWindow() async throws {
        let (model, studio) = try await timelineModel(
            try await timelinePackage(in: folder.url, tracks: 1, seconds: 20), app: app)
        let (lanesWindow, view) = standaloneLanes(model, studio, onScreen: true)
        weak let proxy = view.linkProxy
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
