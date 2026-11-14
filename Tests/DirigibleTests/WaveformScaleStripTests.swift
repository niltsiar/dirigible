import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The dB scale strip at the trailing edge of the track headers: 20 pt beside each lane, inside the
/// vertical ruler, so the header rows keep their width.
@Suite(.serialized) @MainActor struct WaveformScaleStripTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws {
        NSWindow.allowsAutomaticWindowTabbing = false
        folder = try TemporaryFolder()
    }

    /// A standalone window of 1440 pt of lanes plus the header `width` and the strip, with the lanes
    /// of a 2-track package of 60 s at `laneHeight` points.
    func standalone(width: HeaderWidth = .standard, laneHeight: Double = 100, range: WaveformRange = .db60)
        async throws -> (NSWindow, TimelineScrollView, SessionWindow)
    {
        let package = folder.url.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let (model, studio) = try await timelineModel(
            try await timelinePackage(in: package, tracks: 2, seconds: 60), app: app)
        let window = NSWindow(
            contentRect: NSRect(
                x: 0, y: 0, width: 1440 + width.points + WaveformScaleStrip.width + scrollerWidth,
                height: 400 + scrollerWidth),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let view = TimelineScrollView(model: model, studio: studio, headerWidth: width)
        view.frame = try #require(window.contentView).bounds
        window.contentView?.addSubview(view)
        var inputs = laneInputs(model, studio)
        inputs.laneHeight = laneHeight
        inputs.range = range
        view.update(inputs)
        view.update(inputs)
        drawNow(window)
        return (window, view, model)
    }

    /// A mouse event at the ruler x `x` of the header column, at the middle height. A mouse-down
    /// goes to the hit view of the frame view, as the window does: `down` returns that view.
    func event(
        _ type: NSEvent.EventType, _ x: Double, _ view: TimelineScrollView, clicks: Int = 1,
        flags: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        let window = try #require(view.window)
        let location = view.headers.convert(NSPoint(x: x, y: view.headers.bounds.midY), to: nil)
        return try #require(
            NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: clicks, pressure: 1))
    }

    func hit(_ x: Double, _ view: TimelineScrollView) throws -> NSView? {
        let window = try #require(view.window)
        drawNow(window)
        return window.contentView?.superview?.hitTest(try event(.leftMouseDown, x, view).locationInWindow)
    }

    /// The rows keep the header width: the ruler is the header width plus 20 pt, so M and S still
    /// show on one line at the standard width.
    @Test func theRowsKeepTheHeaderWidth() async throws {
        let (_, view, _) = try await standalone()
        #expect(view.headers.width.points == 340)
        #expect(
            Double(view.headers.ruleThickness) == 340 + WaveformScaleStrip.width,
            "the ruler is the header width plus the strip"
        )
        #expect(view.headers.host.frame.width == 340, "the rows keep the header width")
        #expect(view.headers.strip.frame.minX == 340 && view.headers.strip.frame.width == WaveformScaleStrip.width)
        #expect(TrackHeaders.boxes(width: view.headers.host.frame.width, twoLines: false) == .all, "M and S show")
    }

    /// The edge line, the handle, and the saved width read one column edge: a drag of 40 pt from the
    /// handle saves 380, not 400.
    @Test func theColumnEdgeIsOneValue() async throws {
        let (_, view, _) = try await standalone()
        let headers = view.headers
        #expect(headers.columnWidth == 360 && headers.ruleThickness == 360)
        #expect(headers.edge.frame.minX == 359, "the edge line is the last point of the column")
        #expect(headers.handle.frame.minX == 354, "the handle covers the trailing 6 pt")
        var saved: [HeaderWidth] = []
        headers.save = { saved.append($0) }
        let down = try event(.leftMouseDown, 357, view)
        try #require(try hit(357, view) === headers.handle)
        headers.handle.mouseDown(with: down)
        headers.handle.mouseDragged(with: try event(.leftMouseDragged, 397, view))
        headers.handle.mouseUp(with: try event(.leftMouseUp, 397, view))
        #expect(headers.width.points == 380 && headers.ruleThickness == 400)
        #expect(saved == [HeaderWidth(380)], "the saved width is the rows width")
    }

    /// -6 dB is at 10 pt at 60 dB and at 6.25 pt at 96 dB in a lane of 100 pt; -24 dB and -R dB are
    /// one tick at 24 dB; a tick under -R dB does not exist.
    @Test func theTicksFollowTheRange() {
        for range in WaveformRange.allCases {
            for tick in WaveformScaleStrip.ticks(range: range, laneHeight: 100) {
                #expect(abs(tick.y - 100 * (1 - range.fraction(dB: tick.dB))) < 1e-9, "the formula of the waveform")
            }
        }
        func ticks(_ range: WaveformRange, _ height: Double = 100) -> [Double] {
            WaveformScaleStrip.ticks(range: range, laneHeight: height).flatMap { [$0.dB, $0.y] }
        }
        #expect(ticks(.db60) == [0, 0, -6, 10, -12, 20, -24, 40, -60, 100])
        #expect(ticks(.db96) == [0, 0, -6, 6.25, -12, 12.5, -24, 25, -96, 100])
        #expect(ticks(.db24) == [0, 0, -6, 25, -12, 50, -24, 100], "-24 dB and -R dB are one tick")
        #expect(ticks(.db36) == [0, 0, -6, 100.0 / 6, -12, 100.0 / 3, -24, 200.0 / 3, -36, 100])
    }

    /// A lane of 47 pt has no label and a lane of 48 pt has labels that do not touch.
    @Test func theLabelsHideUnder48Points() {
        #expect(WaveformScaleStrip.labelled(range: .db60, laneHeight: 47).isEmpty)
        for range in WaveformRange.allCases {
            for height in [48.0, 60, 100, 200] {
                let labels = WaveformScaleStrip.labelled(range: range, laneHeight: height)
                #expect(labels.first?.dB == 0 && labels.last?.dB == -range.dB, "\(range.rawValue) dB at \(height) pt")
                for (above, below) in zip(labels, labels.dropFirst()) {
                    #expect(below.y - above.y >= 9, "\(range.rawValue) dB at \(height) pt: labels touch")
                }
            }
        }
    }

    /// A label is as tall as its text and the draw keeps it inside its lane, so the 0 dB label sits
    /// below the lane top. No two labels of a lane overlap as drawn, at each range and lane height.
    @Test func theLabelsDoNotOverlapAsDrawn() {
        let text = NSAttributedString(string: "-96", attributes: [.font: WaveformScaleStrip.labelFont])
        #expect(WaveformScaleStrip.labelHeight >= text.size().height, "the label height is the text height")
        for range in WaveformRange.allCases {
            for height in LaneHeight.steps where height >= WaveformScaleStrip.labelsFrom {
                let centers = WaveformScaleStrip.labelled(range: range, laneHeight: height)
                    .map { WaveformScaleStrip.labelCenter(y: $0.y, laneHeight: height) }
                for (above, below) in zip(centers, centers.dropFirst()) {
                    #expect(below - above >= WaveformScaleStrip.labelHeight, "\(range.rawValue) dB at \(height) pt")
                }
            }
        }
    }

    /// The strip draws at the first draw and at a change of the range, the lane height, or the lane
    /// count: not at 120 updates of the same inputs and not at 120 drag events of the header handle.
    @Test func theStripDrawsOnlyOnAChange() async throws {
        let (window, view, model) = try await standalone()
        let strip = view.headers.strip
        try #require(strip.draws > 0, "the first draw")
        let draws = strip.draws
        let studio = try #require(model.studio)
        for _ in 0..<120 {
            view.update(laneInputs(model, studio))
            view.headers.place(top: view.contentView.bounds.minY, height: view.lanes.frame.height)
        }
        let down = try event(.leftMouseDown, 357, view)
        try #require(try hit(357, view) === view.headers.handle)
        view.headers.handle.mouseDown(with: down)
        for step in 0..<120 {
            view.headers.handle.mouseDragged(with: try event(.leftMouseDragged, 357 + Double(step % 40), view))
            drawNow(window)
        }
        view.headers.handle.mouseUp(with: try event(.leftMouseUp, 357, view))
        drawNow(window)
        #expect(strip.draws == draws, "the strip drew \(strip.draws - draws) times with no change")

        var inputs = laneInputs(model, studio)
        inputs.range = .db96
        view.update(inputs)
        drawNow(window)
        #expect(strip.draws > draws, "a new range draws")
    }

    /// The ticks are on the pixel rows of the formula: at 60 dB and 100 pt, rows 10, 20, 40, and 99 have ink
    /// at the trailing edge of the strip and row 30 has none; at 96 dB the -6 dB tick moves to 6 pt.
    @Test func theTicksAreDrawnAtTheirRows() async throws {
        for (range, rows, empty) in [(WaveformRange.db60, [10, 20, 40], 30), (.db96, [6, 12, 25], 30)] {
            let (window, view, _) = try await standalone(range: range)
            let strip = view.headers.strip
            let top = Double(view.contentView.contentInsets.top)
            let rep = try #require(strip.bitmapImageRepForCachingDisplay(in: strip.bounds))
            strip.cacheDisplay(in: strip.bounds, to: rep)
            let scale = Double(rep.pixelsHigh) / strip.bounds.height
            func ink(row: Int) -> Bool {
                // The strip starts at the ruler top, and lane 0 is `top` under it.
                let y = Int((top + Double(row)) * scale)
                return (-1...1).contains { offset in
                    let x = Int((strip.bounds.maxX - 3) * scale)
                    return (rep.colorAt(x: x, y: y + offset)?.alphaComponent ?? 0) > 0.2
                }
            }
            for row in rows { #expect(ink(row: row), "\(range.rawValue) dB: a tick at row \(row)") }
            #expect(!ink(row: empty), "\(range.rawValue) dB: no tick at row \(empty)")
            _ = window
        }
    }

    /// A right-click and a Control-click at x `columnWidth - 3`, under the handle, give the menu of the
    /// ranges, and the handle starts no width drag. A plain press there starts the drag.
    @Test func aRightClickOnTheHandleOpensTheRangeMenu() async throws {
        let (window, view, model) = try await standalone()
        defer { withExtendedLifetime(model) {} }
        let headers = view.headers
        let x = headers.columnWidth - 3
        try #require(try hit(x, view) === headers.handle, "the handle covers the trailing 6 pt of the strip")
        let menu = try #require(headers.handle.menu(for: try event(.rightMouseDown, x, view)), "a right-click")
        #expect(menu.items.filter { !$0.isSeparatorItem }.count == WaveformRange.allCases.count + 1)

        var shown: [NSMenu] = []
        headers.strip.present = { menu, _, _ in shown.append(menu) }
        headers.handle.mouseDown(with: try event(.leftMouseDown, x, view, flags: .control))
        headers.handle.mouseDragged(with: try event(.leftMouseDragged, x + 60, view))
        headers.handle.mouseUp(with: try event(.leftMouseUp, x + 60, view))
        #expect(shown.count == 1, "a Control-click shows the menu once")
        #expect(headers.width.points == 340, "a Control-click starts no width drag")

        headers.handle.mouseDown(with: try event(.leftMouseDown, x, view))
        headers.handle.mouseDragged(with: try event(.leftMouseDragged, x + 60, view))
        headers.handle.mouseUp(with: try event(.leftMouseUp, x + 60, view))
        #expect(headers.width.points == 400, "a plain press there drags the width")
        _ = window
    }

    /// At x `columnWidth - 3` the handle wins: a double click goes to the standard header width and the range
    /// stays.
    @Test func aDoubleClickOnTheHandleResetsTheWidth() async throws {
        let (_, view, model) = try await standalone(width: HeaderWidth(480))
        defer { withExtendedLifetime(model) {} }
        model.timeline.waveformRange = .db96
        let x = view.headers.columnWidth - 3
        try #require(try hit(x, view) === view.headers.handle)
        view.headers.handle.mouseDown(with: try event(.leftMouseDown, x, view, clicks: 2))
        view.headers.handle.mouseUp(with: try event(.leftMouseUp, x, view, clicks: 2))
        #expect(view.headers.width.points == 340, "the header width goes to the standard width")
        #expect(model.timeline.waveformRange == .db96, "the range stays")
    }
}
