import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Run 1b criterion H8, the regression gate of the user report L5 ("the waveform went under the
/// track header panel"): in captures of a session window after each header width step, scroll,
/// zoom, page turn, and resize, no lane pixel and no playhead pixel shows in the header column,
/// and the lanes in view show only lane pixels. The lanes have a sentinel palette (each color a
/// magenta), so a class of the capture color finds them in the display color space (D5). Each
/// capture also proves its step in the same capture (tdd, 2bcc129).
@Suite(.serialized) @MainActor struct HeaderPixelTests {
    let folder: TemporaryFolder
    let app: AppDelegate
    /// The mouse-up and the AX step save the width: a domain of the test, removed at the end.
    let domain = "dirigible.tests.\(UUID().uuidString)"

    init() throws {
        NSWindow.allowsAutomaticWindowTabbing = false
        folder = try TemporaryFolder()
        // A peak cache, so the lanes draw the waveform.
        let defaults = try #require(UserDefaults(suiteName: domain))
        app = AppDelegate(recordings: nil, peakCache: folder.url.appending(path: "Peaks"), defaults: defaults)
    }

    /// Every lane color is a distinct magenta: G 16 or less, R and B 160 or more. A capture is in
    /// the display color space: the peak F020F0 came back as DC43E8 (G 67), out of the class.
    static let sentinel = LanePalette(
        lane: 0xFFC0_00C0, clip: 0xFFD0_08D0, peak: 0xFFF0_10F0, rms: 0xFFA0_00B0, missing: 0xFFB0_00A0,
        missingOutline: 0xFFE0_00E0, label: 0xFFA0_0CA0, marker: 0xFFC8_04C8, chapter: 0xFFE8_08E8,
        inPoint: 0xFFB8_02B8, outPoint: 0xFFD8_06D8)

    /// The classes of `classes(_:skip:)`, inline there for speed.
    static func isLane(_ pixel: UInt32) -> Bool {
        let (r, g, b) = (Int(pixel >> 16 & 0xFF), Int(pixel >> 8 & 0xFF), Int(pixel & 0xFF))
        return g < 64 && r > 96 && b > 96 && abs(r - b) < 64
    }

    static func isPlayhead(_ pixel: UInt32) -> Bool {
        let (r, g, b) = (Int(pixel >> 16 & 0xFF), Int(pixel >> 8 & 0xFF), Int(pixel & 0xFF))
        return r > 180 && g < 90 && b < 90
    }

    /// A capture of the window and the pixel access in window points.
    @MainActor struct Capture {
        let image: CGImage
        let window: NSWindow
        /// The bytes of the image, read once: each read of the data provider copies the image.
        let data: CFData

        init(_ window: NSWindow) throws {
            image = try TimelineColorTests.capture(window)
            self.window = window
            data = try #require(image.dataProvider?.data)
        }

        /// The pixel rows and columns of a rect in window points. The capture has row 0 at the top
        /// of the window; the window has y 0 at the bottom.
        func area(_ rect: NSRect) -> (rows: Range<Int>, columns: Range<Int>) {
            let scale = Double(image.width) / window.frame.width
            let rows = Int((window.frame.height - rect.maxY) * scale)..<Int((window.frame.height - rect.minY) * scale)
            return (rows, Int(rect.minX * scale)..<Int(rect.maxX * scale))
        }

        /// The BGRA pixels in `rect` (window points), as `TimelineRulerTests.pixels`.
        func pixels(_ rect: NSRect) throws -> [UInt32] {
            let bytes = try #require(CFDataGetBytePtr(data))
            let (rows, columns) = area(rect)
            var pixels: [UInt32] = []
            pixels.reserveCapacity(rows.count * columns.count)
            for y in rows {
                for x in columns {
                    pixels.append(
                        UnsafeRawPointer(bytes + y * image.bytesPerRow + x * 4).loadUnaligned(as: UInt32.self))
                }
            }
            return pixels
        }

        /// The pixels in `rect` outside the `skip` rects, one per point (every second pixel row and
        /// column at scale 2): the count, the lane pixels, and the playhead pixels. A full count
        /// took 1.2 s per capture in a debug build.
        func classes(_ rect: NSRect, skip: [NSRect]) throws -> (count: Int, lane: Int, playhead: Int) {
            let bytes = try #require(CFDataGetBytePtr(data))
            let (rows, columns) = area(rect)
            let step = max(1, Int(Double(image.width) / window.frame.width))
            let cuts = skip.map(area)
            var (count, lane, playhead) = (0, 0, 0)
            for y in stride(from: rows.lowerBound, to: rows.upperBound, by: step) {
                // The columns of the row without the skipped rects.
                var parts = [columns]
                for cut in cuts where cut.rows.contains(y) {
                    parts = parts.flatMap { part in
                        let (low, high) = (
                            part.clamped(to: cut.columns).lowerBound, part.clamped(to: cut.columns).upperBound
                        )
                        guard low < high else { return [part] }
                        return [part.lowerBound..<low, high..<part.upperBound].filter { !$0.isEmpty }
                    }
                }
                let row = bytes + y * image.bytesPerRow
                for part in parts {
                    for x in stride(from: part.lowerBound, to: part.upperBound, by: step) {
                        let pixel = UnsafeRawPointer(row + x * 4).loadUnaligned(as: UInt32.self)
                        let (r, g, b) = (Int(pixel >> 16 & 0xFF), Int(pixel >> 8 & 0xFF), Int(pixel & 0xFF))
                        count += 1
                        if g < 64 && r > 96 && b > 96 && abs(r - b) < 64 { lane += 1 }
                        if r > 180 && g < 90 && b < 90 { playhead += 1 }
                    }
                }
            }
            return (count, lane, playhead)
        }
    }

    /// The state of the window of the test: the view, and the regions in window points.
    @MainActor struct Scene {
        let window: NSWindow
        let view: TimelineScrollView

        /// The lanes in view: the part of the view that has lane rows.
        var lanes: NSRect { view.lanes.convert(view.shown.intersection(view.lanes.bounds), to: nil) }
        /// The header column beside the lanes in view: the ruler frame at the height of the lanes.
        var headers: NSRect {
            let ruler = view.headers.convert(view.headers.bounds, to: nil)
            return NSRect(x: ruler.minX, y: lanes.minY, width: ruler.width, height: lanes.height)
        }
        /// The times over the lanes in view.
        var times: NSRect {
            let ruler = view.ruler
            let left = ruler.convert(NSPoint(x: view.shown.minX, y: 0), from: view.lanes).x
            return ruler.convert(
                NSRect(x: left, y: 0, width: ruler.bounds.width - left, height: ruler.bounds.height), to: nil)
        }
        /// The scrollers: an overlay knob shows for about 1 s after a scroll.
        var scrollers: [NSRect] {
            [view.horizontalScroller, view.verticalScroller].compactMap { $0 }.filter { !$0.isHidden }
                .map { $0.convert($0.bounds, to: nil) }
        }
        /// The 2 pt column of the playhead, when it is in view.
        var playhead: NSRect? {
            let frame = view.lanes.convert(view.lanes.playhead.frame, to: nil).insetBy(dx: -0.5, dy: 0)
            return frame.intersects(lanes) ? frame : nil
        }
    }

    enum Proof {
        case width(Double)
        case scroll
        case vertical
        case page
    }

    /// Captures the window 200 ms after the step and checks the header column, the lanes in view,
    /// and the proof that the capture shows the step. Gives the capture for the next proof.
    func check(_ step: String, _ scene: Scene, _ proof: Proof, after old: Capture?) async throws -> Capture {
        drawNow(scene.window)
        try await Task.sleep(for: .milliseconds(200))
        let capture = try Capture(scene.window)
        let skip = scene.scrollers + [scene.playhead].compactMap { $0 }
        let under = try capture.classes(scene.headers, skip: skip)
        #expect(under.count > 500, "\(step): the header column is in the capture")
        #expect(under.lane == 0, "lane pixels under the headers at \(step): \(under.lane) of \(under.count)")
        #expect(under.playhead == 0, "playhead pixels under the headers at \(step): \(under.playhead)")
        let over = try capture.classes(scene.lanes, skip: skip)
        #expect(
            Double(over.lane) >= 0.999 * Double(over.count),
            "header pixels over the lanes at \(step): \(over.count - over.lane) of \(over.count) are not lane pixels")

        switch proof {
        case .width(let width):
            let x = scene.view.headers.convert(NSPoint(x: width, y: 0), to: nil).x
            let rows = NSRect(x: 0, y: scene.lanes.minY, width: 1, height: scene.lanes.height)
                .insetBy(dx: 0, dy: 4)
            let inside = try capture.pixels(rows.offsetBy(dx: x - 1, dy: 0))
            let beside = try capture.pixels(rows.offsetBy(dx: x, dy: 0))
            #expect(
                !inside.contains(where: Self.isLane) && beside.allSatisfy(Self.isLane),
                "the capture shows the width \(width) at \(step)")
        case .scroll, .page:
            let old = try #require(old)
            #expect(
                try capture.pixels(scene.times) != old.pixels(scene.times), "the capture shows the scroll at \(step)")
            if case .page = proof {
                #expect(
                    try capture.pixels(scene.lanes) != old.pixels(scene.lanes),
                    "the capture shows the scroll at \(step)")
            }
        case .vertical:
            let old = try #require(old)
            #expect(
                try capture.pixels(scene.headers) != old.pixels(scene.headers),
                "the capture shows the scroll at \(step): the rows moved")
        }
        return capture
    }

    /// A mouse event at the ruler x `x` of the header handle, at the middle height, sent to the
    /// hit view (the handle) for a mouse-down.
    func handle(_ type: NSEvent.EventType, _ x: Double, _ view: TimelineScrollView) throws {
        let window = try #require(view.window)
        let location = view.headers.convert(NSPoint(x: x, y: view.headers.bounds.midY), to: nil)
        let event = try #require(
            NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        switch type {
        case .leftMouseDown:
            drawNow(window)
            let hit = window.contentView?.superview?.hitTest(location)
            try #require(hit === view.headers.handle, "the handle takes the mouse-down at x \(x)")
            view.headers.handle.mouseDown(with: event)
        case .leftMouseDragged: view.headers.handle.mouseDragged(with: event)
        default: view.headers.handle.mouseUp(with: event)
        }
    }

    @Test func noLanePixelShowsUnderOrOverTheHeaders() async throws {
        let started = ContinuousClock.now
        let package = try await timelinePackage(in: folder.url, tracks: 10, seconds: 20, noise: true)
        let (model, studio, window, view) = try await openLanes(app, package)
        await until(limit: .seconds(30), "the open loads the peaks") { studio.peaks["f1"]?.peaks != nil }
        print("HeaderPixelTests: open and peaks \(ContinuousClock.now - started)")
        window.appearance = NSAppearance(named: .aqua)
        window.setContentSize(NSSize(width: 1180, height: 360))
        // Only the ticks of the test move the playhead: at frame 0, and a page turn.
        view.linkProxy?.view = nil
        // 3,750 pt of lanes; the zoom steps go to 128 and back.
        model.timeline.scale = TimelineScale(framesPerPoint: 256)
        await until("the lanes take 256 frames per point") { view.framesPerPoint == 256 }
        view.lanes.palette = Self.sentinel
        view.tick(playhead: 0, playback: .stopped)
        // The playhead is under the headers at each width step, and never at their edge.
        view.scroll(toFrame: 120 * view.framesPerPoint)
        let scene = Scene(window: window, view: view)
        try #require(view.lanes.frame.height > view.shown.height, "the lanes are taller than the view")
        try #require(view.lanes.frame.width > view.shown.maxX + 1000, "the lanes are wider than the view")

        var capture = try await check("the start", scene, .width(340), after: nil)
        try handle(.leftMouseDown, 337, view)
        for (pointer, width) in [(297.0, 300.0), (97, 180), (257, 260), (557, 480)] {
            try handle(.leftMouseDragged, pointer, view)
            capture = try await check("a drag to \(width)", scene, .width(width), after: capture)
        }
        try handle(.leftMouseUp, 557, view)
        capture = try await check("the mouse-up at 480", scene, .width(480), after: capture)
        try handle(.leftMouseDown, 477, view)
        try handle(.leftMouseDragged, 377, view)
        window.sendEvent(try cgKey(53))
        capture = try await check("Esc in a drag", scene, .width(480), after: capture)
        try handle(.leftMouseUp, 377, view)
        _ = view.headers.handle.accessibilityPerformDecrement()
        capture = try await check("an AX decrement", scene, .width(460), after: capture)

        for width in [180.0, 480] {
            try handle(.leftMouseDown, Double(view.headers.ruleThickness) - 3, view)
            try handle(.leftMouseDragged, width - 3, view)
            try handle(.leftMouseUp, width - 3, view)
            capture = try await check("the width \(width)", scene, .width(width), after: capture)
            for x in [720, 1333.37, 2100.5] {
                view.scroll(toFrame: x * view.framesPerPoint)
                capture = try await check("\(width): a scroll to \(x) pt", scene, .scroll, after: capture)
            }
            let top = view.contentView.bounds.minY
            view.contentView.scroll(to: NSPoint(x: view.contentView.bounds.minX, y: top + 100))
            view.reflectScrolledClipView(view.contentView)
            try #require(view.contentView.bounds.minY - top >= 50, "\(width): a vertical scroll of 50 pt or more")
            capture = try await check("\(width): a vertical scroll", scene, .vertical, after: capture)
            let forward = Playback.playing(Shuttle(direction: .forward, rate: .one))
            view.tick(playhead: view.origin + 0.5 * view.visibleFrames, playback: forward)
            view.tick(playhead: view.origin + 0.95 * view.visibleFrames, playback: forward)
            capture = try await check("\(width): a page turn", scene, .page, after: capture)
            let zoom = view.framesPerPoint == 256 ? 0.5 : 2
            view.zoom(by: zoom, at: 300)
            try #require(view.framesPerPoint == 256 * zoom || view.framesPerPoint == 128 * zoom, "\(width): the zoom")
            capture = try await check("\(width): a zoom by \(zoom) at the pointer", scene, .scroll, after: capture)
        }
        var frame = window.frame
        frame.size.width -= 200
        window.setFrame(frame, display: true)
        capture = try await check("a window 200 pt narrower", scene, .scroll, after: capture)
        print("HeaderPixelTests: all \(ContinuousClock.now - started)")
        window.close()
        await model.close()
        UserDefaults().removePersistentDomain(forName: domain)
    }
}
