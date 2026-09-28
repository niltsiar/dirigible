import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleTimeline
import Testing

@testable import DirigibleApp

/// Timeline-navigation criteria N4, N5, N6, N8b: the overview strip above the ruler, its pixels on
/// screen, its render count guard, and its layers with no actions.
@Suite(.serialized) @MainActor struct OverviewStripTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws { folder = try TemporaryFolder() }

    func pane(onScreen: Bool = false) async throws -> (SessionWindow, Studio, NSWindow, TimelinePaneView) {
        try await stripPane(folder, app, onScreen: onScreen)
    }

    /// The SwiftUI update after a change of the Studio session or the Marks.
    func swiftUIUpdate(_ pane: TimelinePaneView, _ model: SessionWindow, _ studio: Studio) {
        pane.scroll.update(laneInputs(model, studio, marks: model.timeline.marks))
    }

    /// N4: the strip bottom is the ruler top; 8 tracks at the automatic height all fit under the
    /// strip in the default window (3 tracks take 120 pt lanes and fit with no subtraction).
    @Test func theOverviewSitsAboveTheRulerAndTheLanesStillFit() async throws {
        let (model, _, window, view) = try await openLanes(
            app, try await timelinePackage(in: folder.url, tracks: 8, seconds: 20))
        let strip = try #require(view.overview)
        await until("the lanes take the automatic height") {
            window.contentView?.layoutSubtreeIfNeeded()
            return (view.lanes.inputs?.laneHeight ?? 120) < 120
        }
        let stripBottom = strip.convert(strip.bounds, to: nil).minY
        let rulerTop = view.ruler.convert(view.ruler.bounds, to: nil).maxY
        #expect(abs(stripBottom - rulerTop) <= 0.5, "the strip bottom \(stripBottom) is the ruler top \(rulerTop)")
        #expect(Double(strip.frame.height) == OverviewGeometry.height)
        #expect(
            view.lanes.frame.height <= view.shown.height + 0.5,
            "all lanes fit under the overview: \(view.lanes.frame.height) in \(view.shown.height)")
        await model.close()
    }

    /// N5 (U7, U8): a capture of the window shows the clip rows in the waveform color, the row gap,
    /// the tint of a selected lane in its gap, the band, the ticks, the playhead, the dim outside
    /// the frame, and after an edit the new gap (not a stale image).
    @Test func theOverviewDrawsTheSessionAndTheView() async throws {
        let (model, studio, window, pane) = try await pane(onScreen: true)
        let (view, strip) = (pane.scroll, pane.overview)
        try studio.edit { s throws(SessionError) in
            try s.setMarker(Marker(id: "m", name: "M", position: 240_000, kind: .marker))
            try s.setMarker(Marker(id: "c", name: "C", position: 384_000, kind: .chapter))
            try s.clear(288_000..<336_000, on: "t2")
        }
        model.timeline.marks = Marks(inPoint: 144_000, outPoint: 192_000, tracks: ["t2"])
        swiftUIUpdate(pane, model, studio)
        // 0 to 12 s in view from frame 10,000: the frame starts at a fractional point.
        view.navigate(.zoomTo(Zoom(scale: TimelineScale(framesPerPoint: 400), origin: 10_000), stroke: .changed))
        view.tick(playhead: 432_000, playback: .stopped)
        drawNow(window)
        try await Task.sleep(for: .milliseconds(100))

        let scale = window.backingScaleFactor
        try #require(scale == 2, "the rows are for a 56 px strip; this display has scale \(scale)")
        let frame = strip.viewFrame.frame
        #expect(
            (frame.minX * scale).rounded() == frame.minX * scale
                && (frame.maxX * scale).rounded() == frame.maxX * scale,
            "the frame border is on whole pixels: \(frame)")
        #expect(strip.viewFrame.borderWidth == 1)

        let columns = Int(strip.bounds.width * scale)
        let extent = Viewport.extent(end: studio.session.end, rate: 48_000)
        func x(_ frame: Int) -> Double { Double(frame) / extent * strip.bounds.width }
        var shot = try Shot(window, strip)
        let palette = LanePalette.light
        shot.expect(x(48_000), row: 5, palette.rms, "the clip rows use the waveform color")
        shot.expect(x(48_000), row: 18, palette.lane, "a 1 px gap between the rows")
        shot.expect(x(312_000), row: 28, palette.selected(palette.lane), "the gap of a selected lane is tinted")
        shot.expect(x(168_000), row: 45, palette.selected(palette.rms), "the band")
        shot.expect(x(504_000), row: 5, palette.rms, "the clip before the edit")
        let marker = Int(240_000 / extent * Double(columns))
        let chapter = Int(384_000 / extent * Double(columns))
        shot.expect(column: marker, row: 2, palette.marker, "a marker tick")
        #expect(!shot.near(column: marker, row: 20, palette.marker), "a marker tick is short")
        shot.expect(column: chapter, row: 20, palette.chapter, "a chapter tick")
        let markerPixels = (0..<56).filter { shot.near(column: marker, row: $0, palette.marker) }.count
        let chapterPixels = (0..<56).flatMap { row in [chapter, chapter + 1].map { (row, $0) } }
            .filter { shot.near(column: $0.1, row: $0.0, palette.chapter) }.count
        #expect(
            chapterPixels > 2 * markerPixels, "a chapter tick is stronger: \(chapterPixels) against \(markerPixels)")
        #expect(!shot.near(column: chapter, row: 50, palette.chapter), "the playhead is the only full-height line")
        let playhead = Int(strip.playhead.frame.minX * scale)
        #expect((0..<56).allSatisfy { shot.red(column: playhead, row: $0) }, "the playhead is a full-height line")
        let dimmed = shot.pixel(column: Int(x(720_000) * scale), row: 18)
        #expect(dimmed.allSatisfy { $0 < 0xE8 - 20 }, "the part outside the frame is dimmed: \(dimmed)")

        try studio.edit { s throws(SessionError) in try s.clear(480_000..<528_000, on: "t1") }
        swiftUIUpdate(pane, model, studio)
        drawNow(window)
        try await Task.sleep(for: .milliseconds(100))
        shot = try Shot(window, strip)
        shot.expect(x(504_000), row: 5, palette.lane, "after Split and Delete the gap shows")

        window.appearance = NSAppearance(named: .darkAqua)
        drawNow(window)
        try await Task.sleep(for: .milliseconds(100))
        shot = try Shot(window, strip)
        shot.expect(x(48_000), row: 5, strip.palette.lanes.peak, "the clip rows use the waveform color")
        #expect(strip.palette.lanes.accent != nil, "the dark palette")
        window.close()
        await model.close()
    }

    /// U8: with Increase Contrast the frame border is 2 pt in the label color.
    @Test func theIncreaseContrastFrameIsTwoPoints() async throws {
        let (model, _, window, pane) = try await pane()
        pane.overview.pickPalette(increaseContrast: true)
        drawNow(window)
        #expect(pane.overview.viewFrame.borderWidth == 2, "the border is 2 pt with Increase Contrast")
        pane.overview.pickPalette(increaseContrast: false)
        drawNow(window)
        #expect(pane.overview.viewFrame.borderWidth == 1)
        window.close()
        await model.close()
    }

    /// N6: the image renders only when a drawn input changes: not at a zoom, a scroll, a page, a
    /// play tick, a drag event, or a live resize step; once after the up, an edit, an undo, and the
    /// end of a live resize.
    @Test func theOverviewRendersOnlyWhenItsInputsChange() async throws {
        let (model, studio, window, pane) = try await pane()
        let (view, strip) = (pane.scroll, pane.overview)
        func renders(_ action: () throws -> Void) rethrows -> Int {
            let before = strip.renders
            try action()
            drawNow(window)
            return strip.renders - before
        }
        #expect(strip.renders >= 1, "the strip renders at open")
        #expect(renders { view.navigate(.zoom(by: 0.5)) } == 0, "a zoom renders no overview")
        #expect(renders { view.navigate(.zoom(by: 0.5, at: 300)) } == 0, "a zoom renders no overview")
        #expect(renders { view.navigate(.scroll(to: 100_000)) } == 0, "a scroll renders no overview")
        #expect(renders { view.navigate(.page(.forward)) } == 0, "a page renders no overview")
        let play = Playback.playing(Shuttle(direction: .forward, rate: .one))
        #expect(renders { for n in 0..<60 { view.tick(playhead: Double(n * 800), playback: play) } } == 0)
        view.tick(playhead: 0, playback: .stopped)
        view.navigate(.fitSession)
        drawNow(window)

        // A clip move: 20 events, then the up commits the move.
        try view.lanes.mouseDown(with: mouse(.leftMouseDown, NSPoint(x: 100, y: 20), in: view))
        let moves = try renders {
            for n in 1...20 {
                try view.lanes.mouseDragged(with: mouse(.leftMouseDragged, NSPoint(x: 100 + n * 5, y: 20), in: view))
                swiftUIUpdate(pane, model, studio)
            }
        }
        #expect(moves == 0, "a drag renders no overview")
        #expect(
            try renders {
                try view.lanes.mouseUp(with: mouse(.leftMouseUp, NSPoint(x: 200, y: 20), in: view))
                swiftUIUpdate(pane, model, studio)
            } == 1, "the up renders the overview once")

        // A range drag in the lower third of lane 2: the Marks change at each event.
        try view.lanes.mouseDown(with: mouse(.leftMouseDown, NSPoint(x: 400, y: 180), in: view))
        let ranges = try renders {
            for n in 1...20 {
                try view.lanes.mouseDragged(with: mouse(.leftMouseDragged, NSPoint(x: 400 + n * 5, y: 180), in: view))
                swiftUIUpdate(pane, model, studio)
            }
        }
        #expect(ranges == 0, "a drag renders no overview")
        #expect(
            try renders {
                try view.lanes.mouseUp(with: mouse(.leftMouseUp, NSPoint(x: 500, y: 180), in: view))
                swiftUIUpdate(pane, model, studio)
            } == 1, "the up renders the overview once")

        let edit = try renders {
            try studio.edit { s throws(SessionError) in _ = try s.splitClips(at: [240_000], on: ["t3"]) }
            swiftUIUpdate(pane, model, studio)
        }
        #expect(edit == 1, "an edit renders the overview once")
        #expect(
            renders {
                model.undo()
                swiftUIUpdate(pane, model, studio)
            } == 1, "an undo renders the overview once")

        strip.viewWillStartLiveResize()
        let steps = renders {
            for _ in 1...10 {
                window.setContentSize(NSSize(width: window.frame.width - 10, height: window.frame.height))
                pane.frame = window.contentView!.bounds
                drawNow(window)
            }
        }
        #expect(steps == 0, "a live resize renders once at the end")
        #expect(renders { strip.viewDidEndLiveResize() } == 1, "a live resize renders once at the end")
        window.close()
        await model.close()
    }

    /// N8b (U12): no layer of the strip animates, `contents` included.
    @Test func theOverviewLayersHaveNoActions() async throws {
        let (model, _, window, pane) = try await pane()
        let strip = pane.overview
        for layer in [strip.image, strip.dimLeading, strip.dimTrailing, strip.viewFrame, strip.playhead] {
            for key in ["position", "bounds", "frame", "contents", "hidden", "backgroundColor", "borderColor"] {
                #expect(layer.action(forKey: key) == nil, "no layer animates \(key)")
            }
        }
        window.close()
        await model.close()
    }

    /// The clip view owns the origin: an AppKit scroll moves the frame with no `navigate`.
    @Test func aScrollOfTheClipViewMovesTheFrame() async throws {
        let (model, _, window, pane) = try await pane()
        let (view, strip) = (pane.scroll, pane.overview)
        view.navigate(.zoomTo(Zoom(scale: TimelineScale(framesPerPoint: 128), origin: 0), stroke: .changed))
        drawNow(window)
        let before = strip.viewFrame.frame.midX
        view.contentView.scroll(to: NSPoint(x: view.contentView.bounds.minX + 500, y: view.contentView.bounds.minY))
        view.reflectScrolledClipView(view.contentView)
        let moved = strip.viewFrame.frame.midX - before
        let expected = 500 * 128 / (Viewport.extent(end: 960_000, rate: 48_000) / strip.bounds.width)
        #expect(abs(moved - expected) <= 1, "the frame follows the clip view: \(moved) against \(expected)")
        window.close()
        await model.close()
    }
}

/// A pane with 1440 pt of lanes and the 340 pt headers under a 28 pt strip, at 512 frames per
/// point and 100 pt lanes: 3 tracks of a 20 s clip each.
@MainActor func stripPane(_ folder: TemporaryFolder, _ app: AppDelegate, onScreen: Bool = false) async throws
    -> (SessionWindow, Studio, NSWindow, TimelinePaneView)
{
    let (model, studio) = try await timelineModel(
        try await timelinePackage(in: folder.url, tracks: 3, seconds: 20), app: app)
    let window = NSWindow(
        contentRect: NSRect(
            x: 0, y: 0, width: 1440 + HeaderWidth.standard.points + scrollerWidth,
            height: OverviewGeometry.height + 400 + scrollerWidth),
        styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .aqua)
    let pane = TimelinePaneView(scroll: TimelineScrollView(model: model, studio: studio))
    pane.frame = try #require(window.contentView).bounds
    window.contentView?.addSubview(pane)
    pane.scroll.update(laneInputs(model, studio))
    pane.scroll.update(laneInputs(model, studio))
    // The ticks of the test, not of the display link: a link tick seeks to the Studio playhead.
    pane.scroll.viewWillMove(toWindow: nil)
    if onScreen { window.orderFront(nil) }
    drawNow(window)
    return (model, studio, window, pane)
}

/// A capture of a window, read at the pixels of the strip.
@MainActor struct Shot {
    let image: CGImage
    let bytes: UnsafePointer<UInt8>
    let data: CFData
    /// The pixel of the strip top left in the capture.
    let origin: (x: Int, y: Int)
    let scale: Double

    init(_ window: NSWindow, _ strip: NSView) throws {
        image = try TimelineColorTests.capture(window)
        data = try #require(image.dataProvider?.data)
        bytes = try #require(CFDataGetBytePtr(data))
        try #require(image.bitsPerPixel == 32 && image.bitmapInfo.contains(.byteOrder32Little))
        scale = Double(image.width) / window.frame.width
        let top = strip.convert(NSPoint(x: 0, y: 0), to: nil)
        origin = (Int((top.x * scale).rounded()), Int(((window.frame.height - top.y) * scale).rounded()))
    }

    /// RGB of the pixel at `column` and `row` of the strip.
    func pixel(column: Int, row: Int) -> [Int] {
        let offset = (origin.y + row) * image.bytesPerRow + (origin.x + column) * 4
        return [Int(bytes[offset + 2]), Int(bytes[offset + 1]), Int(bytes[offset])]
    }

    /// True when the pixel shows the sRGB `color` in the color space of the display, within 3 per
    /// channel: the window server converts the sRGB image to the display.
    func near(column: Int, row: Int, _ color: UInt32) -> Bool {
        func channel(_ shift: UInt32) -> CGFloat { CGFloat((color >> shift) & 0xFF) / 255 }
        let srgb = CGColor(srgbRed: channel(16), green: channel(8), blue: channel(0), alpha: 1)
        guard let space = image.colorSpace, let shown = srgb.converted(to: space, intent: .defaultIntent, options: nil),
            let components = shown.components, components.count >= 3
        else { return false }
        let expected = components.prefix(3).map { Int(($0 * 255).rounded()) }
        return zip(pixel(column: column, row: row), expected).allSatisfy { abs($0 - $1) <= 3 }
    }

    /// At the strip point `x`.
    func near(_ x: Double, row: Int, _ color: UInt32) -> Bool { near(column: Int(x * scale), row: row, color) }

    func expect(column: Int, row: Int, _ color: UInt32, _ message: String) {
        #expect(
            near(column: column, row: row, color), "\(message): \(pixel(column: column, row: row)) at \(column), \(row)"
        )
    }

    func expect(_ x: Double, row: Int, _ color: UInt32, _ message: String) {
        expect(column: Int(x * scale), row: row, color, message)
    }

    func red(column: Int, row: Int) -> Bool {
        let rgb = pixel(column: column, row: row)
        return rgb[0] > 180 && rgb[1] < 100 && rgb[2] < 100
    }
}
