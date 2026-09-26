import AppKit
import DirigibleCore
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

    /// The lanes of a session window on screen, 1440 x 600 pt in view, with the inputs of the 2 h
    /// fixture at `framesPerPoint`. The window of a 1 s package gives the model and the studio.
    static func lanesOnScreen(
        _ session: Session, _ peaks: [FileID: PeakState], framesPerPoint: Double, app: AppDelegate, folder: URL
    ) async throws -> (NSWindow, TimelineScrollView, SessionWindow) {
        let (model, studio) = try await timelineModel(
            try await timelinePackage(in: folder, tracks: 1, seconds: 1), app: app)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440 + TrackHeaderRuler.width, height: 660),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = TimelineScrollView(model: model, studio: studio)
        view.frame = try #require(window.contentView).bounds
        window.contentView?.addSubview(view)
        let inputs = LaneInputs(
            session: session, peaks: peaks, missingMedia: [:], marks: Marks(),
            scale: TimelineScale(framesPerPoint: framesPerPoint), laneHeight: 100)
        // The first update fits the session; the second sets the zoom of the test.
        view.update(inputs)
        view.update(inputs)
        window.orderFront(nil)
        drawNow(window)
        return (window, view, model)
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
}
