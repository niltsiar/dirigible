import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import SwiftUI
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Timeline-navigation criterion N22: one overview drag event on the 2 h fixture fits one 60 Hz
/// frame, p95 16 ms or less with -O (`make bench FILTER=OverviewBenchmark`); the debug proxy
/// budget is 150 ms: an edge drag from the fit measured 84 to 93 ms p95 in debug (a full lane
/// render at fit and the SwiftUI update). An event is `navigate`, the SwiftUI update of the
/// pane (the header rows and the lane inputs, as `updateNSView` does), and the lane render, timed
/// to the end of `drawNow`. Each timed event must change the view and render the lanes once, and
/// the strip above the lanes renders no image. 1440 x 608 pt of lanes at scale 2.
@MainActor struct OverviewBenchmark {
    #if DEBUG
        static let budget = 150
    #else
        static let budget = 16
    #endif
    /// The overview frames per point: the 2 h fixture + 2% over a 1440 pt strip.
    static let overview = Double(MouseEventBenchmark.frames) * 1.02 / 1440

    /// A frame drag: each event jumps 1.5 view widths, so no column of the last window is in view
    /// (a full lane render), at the closest zoom and at the zoom of 60 pt boxes. At the fit a frame
    /// drag moves nothing (plan gate item 4). Past the last page the drag goes back to 0.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func anOverviewFrameDragEventFitsOneFrameAtTwoHours() async throws {
        let zooms = [("closest zoom", 128.0), MouseEventBenchmark.zooms[1]]
        try await Self.eachZoom(zooms) { name, view in
            let last = Double(MouseEventBenchmark.frames) * 1.02 - view.visibleFrames
            let jump = 1.5 * view.visibleFrames
            return .scroll(to: view.origin + jump > last ? 0 : view.origin + jump)
        }
    }

    /// An edge drag: the trailing edge moves 4 pt of overview per event and the leading edge stays,
    /// so each event is a zoom (a new document width and a full lane render). From the fit it
    /// zooms in; from 60 pt boxes it zooms out.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func anOverviewEdgeDragEventFitsOneFrameAtTwoHours() async throws {
        let zooms = [("fit", Self.overview), MouseEventBenchmark.zooms[1]]
        try await Self.eachZoom(zooms) { name, view in
            let step = (name == "fit" ? -4 : 4) * Self.overview
            let frames = view.visibleFrames + step
            return .zoomTo(
                Zoom(scale: TimelineScale(framesPerPoint: frames / 1440), origin: view.origin), stroke: .changed)
        }
    }

    /// N21: one strip render after an edit, 2880 x 56 px, 4 ms p95 or less with -O (250 ms in debug,
    /// a proxy: the debug pixel loops measured 93 to 97 ms p95). The worst case: 12,000 clips at fit, a change at the session end (the last clip of
    /// t6 one frame shorter, then back), and 6 selected lanes with the tint. The time is the render
    /// and the commit of the new image; each event must render once.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func anOverviewRenderAfterAnEditFitsFourMilliseconds() async throws {
        #if DEBUG
            let budget = 250
        #else
            let budget = 4
        #endif
        var (session, _) = try MouseEventBenchmark.fixture()
        let last = try #require(session.tracks[5].clips.last)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: OverviewGeometry.height), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let strip = OverviewStrip(frame: try #require(window.contentView).bounds)
        window.contentView?.addSubview(strip)
        window.orderFront(nil)
        try #require(window.backingScaleFactor == 2, "this display has scale \(window.backingScaleFactor)")
        let extent = Viewport.extent(end: session.end, rate: 48_000)
        var times: [Duration] = []
        for event in 1...130 {
            try session.trim(last.id, to: last.start..<last.end - Frames(event % 2))
            let inputs = OverviewInputs(session: session, selection: nil, selectedLanes: Array(0..<6), extent: extent)
            let renders = strip.renders
            try await Task.sleep(for: .microseconds(16_700))
            let start = ContinuousClock.now
            strip.inputs = inputs
            drawNow(window)
            if event > 10 { times.append(ContinuousClock.now - start) }
            try #require(strip.renders == renders + 1, "each edit renders the strip once")
        }
        let sorted = times.sorted()
        let p95 = sorted[Int(Double(sorted.count) * 0.95)]
        print("OverviewBenchmark render: p50 \(sorted[sorted.count / 2]), p95 \(p95), max \(sorted.last!)")
        expectWithinBudget(p95, .milliseconds(budget), "p95: render \(p95)")
        window.close()
    }

    /// 70 events per zoom, one per 60 Hz frame; the last 60 are timed.
    static func eachZoom(
        _ zooms: [(String, Double)], _ input: @MainActor (String, TimelineScrollView) -> NavigationInput
    ) async throws {
        let folder = try TemporaryFolder()
        let app = AppDelegate(recordings: nil)
        let (session, peaks) = try MouseEventBenchmark.fixture()
        for (n, (zoom, framesPerPoint)) in zooms.enumerated() {
            let package = folder.url.appending(path: "\(n)")
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            let (window, view, model, inputs) = try await MouseEventBenchmark.lanesAndInputs(
                session, peaks, framesPerPoint: framesPerPoint, app: app, folder: package)
            view.viewWillMove(toWindow: nil)
            // The pane of `lanesAndInputs` has the strip above the lanes; its layers move at each event.
            let strip = try #require(view.overview)
            if zoom != "fit" {
                // The middle of the session, so a zoom out has room on both sides.
                view.scroll(toFrame: 100_000_000)
                drawNow(window)
            }
            let studio = try #require(model.studio)
            try #require(window.backingScaleFactor == 2, "this display has scale \(window.backingScaleFactor)")
            try #require(view.shown.width == 1440 && view.shown.height >= 600, "\(view.shown)")
            var times: [Duration] = []
            let renders = strip.renders
            for event in 1...70 {
                let (origin, scale, draws) = (view.origin, view.framesPerPoint, view.lanes.draws)
                try await Task.sleep(for: .microseconds(16_700))
                let start = ContinuousClock.now
                view.navigate(input(zoom, view))
                // The SwiftUI update of the pane: a new scale or visible part runs its body.
                view.headers.host.rootView = AnyView(TrackHeaders(model: model, studio: studio, laneHeight: 100))
                MouseEventBenchmark.swiftUIUpdate(view, model, inputs)
                drawNow(window)
                if event > 10 { times.append(ContinuousClock.now - start) }
                try #require(
                    view.lanes.draws == draws + 1,
                    "each event draws the lanes: \(zoom) event \(event) drew \(view.lanes.draws - draws)")
                try #require(
                    view.origin != origin || view.framesPerPoint != scale, "\(zoom): event \(event) moved nothing")
            }
            try #require(strip.renders == renders, "\(zoom): a drag renders no overview")
            let sorted = times.sorted()
            let p95 = sorted[Int(Double(sorted.count) * 0.95)]
            print("OverviewBenchmark \(zoom): p50 \(sorted[sorted.count / 2]), p95 \(p95), max \(sorted.last!)")
            expectWithinBudget(p95, .milliseconds(budget), "p95: \(zoom) \(p95)")
            window.close()
            await model.close()
        }
    }
}
