import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Mouse-edits criterion 15: one mouse event on the 2 h fixture fits one 60 Hz frame, p95 16 ms
/// or less over 120 events with -O (`make bench FILTER=MouseEventBenchmark`). The debug budget of
/// `make test-slow` is a proxy only: 100 ms, because the debug draw at fit zoom measured 75 ms. The 2 h fixture: 6 mono tracks of 2 h (345,600,000
/// frames at 48 kHz), 2,000 clips per track, peaks ready, 100 pt lanes, 1440 x 600 pt at scale 2.
@MainActor struct MouseEventBenchmark {
    #if DEBUG
        static let budget = Duration.milliseconds(100)
    #else
        static let budget = Duration.milliseconds(16)
    #endif
    static let frames = 345_600_000
    /// The frames per point of fit zoom, and of the zoom that makes each clip box 60 pt wide (the
    /// most labels).
    static let zooms = [("fit", Double(frames) / 1440), ("60 pt boxes", Double(frames / 2000) / 60)]

    /// The session of the 2 h fixture and its peaks: one clip of the whole file on each track, split
    /// every 172,800 frames, so clip n of a track has frames n x 172,800 of its file at the same
    /// place on the timeline. One split call: 12,000 `place` calls take minutes in debug.
    static func fixture() throws -> (Session, [FileID: PeakState]) {
        let peaks = randomPeaks(frames: frames)
        var session = Session(sampleRate: 48_000)
        var states: [FileID: PeakState] = [:]
        let tracks = (1...6).map { TrackID("t\($0)") }
        for (n, track) in tracks.enumerated() {
            let file = FileID("f\(n + 1)")
            try session.addFile(AudioFile(id: file, path: "take1-\(n + 1).wav", layout: .mono, length: Frames(frames)))
            try session.addTrack(track, name: "T\(n + 1)", layout: .mono)
            try session.place(
                Clip(id: ClipID("c\(n + 1)"), file: file, start: 0, offset: 0, length: Frames(frames)), on: track)
            states[file] = .ready(peaks)
        }
        _ = try session.splitClips(at: (1..<2000).map { Frames($0 * frames / 2000) }, on: tracks)
        #expect(session.tracks.allSatisfy { $0.clips.count == 2000 })
        return (session, states)
    }

    /// The lanes of a session window on screen under the overview strip, 1440 x 608 pt in view, with the inputs of the 2 h
    /// fixture at `framesPerPoint`. The window of a 1 s package gives the model and the studio. The
    /// Studio gets the 2 h session, because a mouse-down reads it, and a save that does not write:
    /// a package write of 12,000 clips must not run during the timed events.
    static func lanesOnScreen(
        _ session: Session, _ peaks: [FileID: PeakState], framesPerPoint: Double, app: AppDelegate, folder: URL,
        laneHeight: Double = 100
    ) async throws -> (NSWindow, TimelineScrollView, SessionWindow) {
        let (window, view, model, _) = try await lanesAndInputs(
            session, peaks, framesPerPoint: framesPerPoint, app: app, folder: folder, laneHeight: laneHeight)
        return (window, view, model)
    }

    /// `lanesOnScreen`, and the inputs of its last update.
    static func lanesAndInputs(
        _ session: Session, _ peaks: [FileID: PeakState], framesPerPoint: Double, app: AppDelegate, folder: URL,
        laneHeight: Double = 100
    ) async throws -> (NSWindow, TimelineScrollView, SessionWindow, LaneInputs) {
        let (model, studio) = try await timelineModel(
            try await timelinePackage(in: folder, tracks: 1, seconds: 1), app: app)
        let url = studio.url
        studio.environment.saveSession = { _, _ in url }
        try studio.edit { s throws(SessionError) in s = session }
        let window = NSWindow(
            contentRect: NSRect(
                x: 0, y: 0, width: 1440 + HeaderWidth.standard.points + scrollerWidth, height: 660 + scrollerWidth),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        // The pane of the app: the overview strip above the lanes (decision 0025).
        let view = TimelineScrollView(model: model, studio: studio)
        let pane = TimelinePaneView(scroll: view)
        pane.frame = try #require(window.contentView).bounds
        window.contentView?.addSubview(pane)
        let inputs = LaneInputs(
            session: session, peaks: peaks, missingMedia: [:], marks: Marks(),
            scale: TimelineScale(framesPerPoint: framesPerPoint), laneHeight: laneHeight)
        // The first update fits the session; the second sets the zoom of the test.
        view.update(inputs)
        view.update(inputs)
        model.timeline.scale = inputs.scale
        window.orderFront(nil)
        // No display link: its autoscroll tick scrolls a drag past the lanes edge (0025), so an end
        // clip move drew twice in one event. The benches time the events, and the autoscroll tick
        // has its own case (`anAutoscrollTickFitsOneFrame`).
        view.viewWillMove(toWindow: nil)
        drawNow(window)
        return (window, view, model, inputs)
    }

    /// Sends 130 drag events of `event(n)` to `target` (the lanes by default), one per 60 Hz frame,
    /// and gives the sorted times of the last 120: the event and the draw that it causes. Each event
    /// must draw the lanes once and change the drawn session. The pointer gives at most about one
    /// coalesced drag event per frame. Back to back, the flush of every second or fourth event
    /// waited for the next display frame (about 17 ms in all, 1.6 ms of gesture and 0.4 ms of draw):
    /// it measured the frame rate, not the event (the mouse-edits run, slice 3). With `swiftUI`, the
    /// timed part also has the SwiftUI update that a change of the window model causes.
    static func pacedDrags(
        _ view: TimelineScrollView, _ window: NSWindow, _ zoom: String, to target: NSView? = nil,
        swiftUI: (model: SessionWindow, inputs: LaneInputs)? = nil, _ event: (Int) throws -> NSEvent
    ) async throws -> [Duration] {
        var times: [Duration] = []
        for n in 1...130 {
            let drag = try event(n)
            let (draws, before) = (view.lanes.draws, view.lanes.inputs)
            try await Task.sleep(for: .microseconds(16_700))
            let start = ContinuousClock.now
            (target ?? view.lanes).mouseDragged(with: drag)
            if let swiftUI { Self.swiftUIUpdate(view, swiftUI.model, swiftUI.inputs) }
            drawNow(window)
            // The first 10 events are not timed (the draw after the window shows).
            if n > 10 { times.append(ContinuousClock.now - start) }
            try #require(
                view.lanes.draws == draws + 1,
                "\(zoom): event \(n) drew \(view.lanes.draws - draws) times, \(view.lanes.inputs?.marks as Any)")
            try #require(view.lanes.inputs != before, "\(zoom): event \(n) changed no drawn input")
        }
        return times.sorted()
    }

    /// The draw of the lanes in view with the labels, 120 times at each zoom, on the path that
    /// AppKit uses on screen: the backing store of the layer, drawn at the commit of the Core
    /// Animation transaction. `cacheDisplay` converts the new image of each draw into its bitmap,
    /// about 30 ms at 2880 x 1200 px on the Intel Mac of run 4d, so it does not measure the app.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func theLanesInViewDrawInOneFrameAtTwoHours() async throws {
        let folder = try TemporaryFolder()
        let app = AppDelegate(recordings: nil)
        let (session, peaks) = try Self.fixture()
        for (n, (zoom, framesPerPoint)) in Self.zooms.enumerated() {
            let package = folder.url.appending(path: "\(n)")
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            let (window, view, model) = try await Self.lanesOnScreen(
                session, peaks, framesPerPoint: framesPerPoint, app: app, folder: package)
            try #require(
                window.backingScaleFactor == 2,
                "the budget is for 2880 x 1200 px; this display has scale \(window.backingScaleFactor)")
            try #require(view.shown.width == 1440 && view.shown.height >= 600, "\(view.shown)")
            // The first draws after the window shows took 155, 48, and 23 ms (the backing store and
            // the window server set up), so 10 draws come first and are not timed.
            for _ in 0..<10 {
                view.lanes.setNeedsDisplay(view.shown)
                drawNow(window)
            }
            var times: [Duration] = []
            for _ in 0..<120 {
                let draws = view.lanes.draws
                view.lanes.setNeedsDisplay(view.shown)
                let start = ContinuousClock.now
                drawNow(window)
                times.append(ContinuousClock.now - start)
                try #require(view.lanes.draws == draws + 1, "one draw per event")
            }
            let sorted = times.sorted()
            print("MouseEventBenchmark draw, \(zoom): p50 \(sorted[60]), p95 \(sorted[113])")
            #expect(sorted[113] <= Self.budget, "\(zoom): p95 \(sorted[113])")
            window.close()
            await model.close()
        }
    }

    /// One move drag event: the gesture step, the move on a copy of the 2 h session, the compare of
    /// the drawn inputs, and the draw of the columns of the changed clips, 120 times at each zoom. Each event moves
    /// the clip 1 pt right and to the other of lanes 2 and 3, so each event makes a new preview. At
    /// fit zoom a fixture clip is 0.72 pt wide, all range zone, so a clip of 20 pt (4,800,000
    /// frames) replaces the clips under it on t2. At the zoom of 60 pt boxes, a fixture clip moves.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aMoveEventFitsOneFrameAtTwoHours() async throws {
        let folder = try TemporaryFolder()
        let app = AppDelegate(recordings: nil)
        var (session, peaks) = try Self.fixture()
        try session.place(
            Clip(id: "big", file: "f2", start: 100_000_000, offset: 100_000_000, length: 4_800_000), on: "t2")
        for (n, (zoom, framesPerPoint)) in Self.zooms.enumerated() {
            let package = folder.url.appending(path: "\(n)")
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            let (window, view, model) = try await Self.lanesOnScreen(
                session, peaks, framesPerPoint: framesPerPoint, app: app, folder: package)
            try #require(window.backingScaleFactor == 2, "this display has scale \(window.backingScaleFactor)")
            let box = try #require(
                n == 0 ? view.lanes.clipFrame("big") : NSRect(x: 300, y: 100, width: 60, height: 100))
            try #require(box.width >= 12 && box.maxX < 1300, "\(zoom): \(box)")
            let down = NSPoint(x: box.midX, y: box.minY + 10)
            view.lanes.mouseDown(with: try mouse(.leftMouseDown, down, in: view))
            let sorted = try await Self.pacedDrags(view, window, zoom) { event in
                try mouse(
                    .leftMouseDragged, NSPoint(x: down.x + Double(event), y: down.y + (event % 2 == 0 ? 0 : 100)),
                    in: view)
            }
            view.lanes.mouseUp(with: try mouse(.leftMouseUp, down, in: view))
            print("MouseEventBenchmark move, \(zoom): p50 \(sorted[60]), p95 \(sorted[113])")
            #expect(sorted[113] <= Self.budget, "\(zoom): p95 \(sorted[113])")
            window.close()
            await model.close()
        }
    }

    /// One end-edge trim event, as the move case: at fit zoom the end of the 20 pt clip, at the zoom
    /// of 60 pt boxes the end of a fixture clip. The next clip holds the end, so each event takes it
    /// 3 to 12 pt left (3 pt is the drag threshold), a new place at each event.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aTrimEventFitsOneFrameAtTwoHours() async throws {
        let folder = try TemporaryFolder()
        let app = AppDelegate(recordings: nil)
        var (session, peaks) = try Self.fixture()
        try session.place(
            Clip(id: "big", file: "f2", start: 100_000_000, offset: 100_000_000, length: 4_800_000), on: "t2")
        for (n, (zoom, framesPerPoint)) in Self.zooms.enumerated() {
            let package = folder.url.appending(path: "\(n)")
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            let (window, view, model) = try await Self.lanesOnScreen(
                session, peaks, framesPerPoint: framesPerPoint, app: app, folder: package)
            try #require(window.backingScaleFactor == 2, "this display has scale \(window.backingScaleFactor)")
            let box = try #require(
                n == 0 ? view.lanes.clipFrame("big") : NSRect(x: 300, y: 100, width: 60, height: 100))
            try #require(box.width >= 12 && box.maxX < 1300, "\(zoom): \(box)")
            let down = NSPoint(x: box.maxX - 2, y: box.minY + 10)
            view.lanes.mouseDown(with: try mouse(.leftMouseDown, down, in: view))
            let sorted = try await Self.pacedDrags(view, window, zoom) { event in
                try mouse(.leftMouseDragged, NSPoint(x: down.x - Double(3 + event % 10), y: down.y), in: view)
            }
            view.lanes.mouseUp(with: try mouse(.leftMouseUp, down, in: view))
            print("MouseEventBenchmark trim, \(zoom): p50 \(sorted[60]), p95 \(sorted[113])")
            #expect(sorted[113] <= Self.budget, "\(zoom): p95 \(sorted[113])")
            window.close()
            await model.close()
        }
    }

    /// One flag drag event on the ruler: the gesture step, `setMarker` on a copy of the 2 h session,
    /// and the draw of the lanes (the marker line) and the ruler. The marker is at x 300 pt; each
    /// event takes its flag 1 pt right.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aFlagDragEventFitsOneFrameAtTwoHours() async throws {
        let folder = try TemporaryFolder()
        let app = AppDelegate(recordings: nil)
        let (fixture, peaks) = try Self.fixture()
        for (n, (zoom, framesPerPoint)) in Self.zooms.enumerated() {
            var session = fixture
            try session.setMarker(
                Marker(id: "m1", name: "Marker 1", position: Frames(Int(framesPerPoint * 300)), kind: .marker))
            let package = folder.url.appending(path: "\(n)")
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            let (window, view, model) = try await Self.lanesOnScreen(
                session, peaks, framesPerPoint: framesPerPoint, app: app, folder: package)
            try #require(window.backingScaleFactor == 2, "this display has scale \(window.backingScaleFactor)")
            view.ruler.mouseDown(with: try rulerMouse(.leftMouseDown, 301, 10, in: view))
            let sorted = try await Self.pacedDrags(view, window, zoom, to: view.ruler) { event in
                try rulerMouse(.leftMouseDragged, 301 + Double(3 + event), 10, in: view)
            }
            view.ruler.mouseUp(with: try rulerMouse(.leftMouseUp, 301, 10, in: view))
            print("MouseEventBenchmark flag, \(zoom): p50 \(sorted[60]), p95 \(sorted[113])")
            #expect(sorted[113] <= Self.budget, "\(zoom): p95 \(sorted[113])")
            window.close()
            await model.close()
        }
    }
}
