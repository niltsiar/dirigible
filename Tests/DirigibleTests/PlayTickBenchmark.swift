import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Ui-shell criterion A24: one display tick during play fits one 60 Hz frame, p95 16 ms or less
/// over 600 ticks with -O (`make bench FILTER=PlayTickBenchmark`), 100 ms in debug (a proxy). The
/// research target is 2 ms. A tick is the poll write of the playhead, the chrome loop turn (the
/// item states, the record-over rule, the time display), the playhead line and the follow, and
/// the draw. The 2 h fixture of `MouseEventBenchmark`, 1440 x 600 pt of lanes at scale 2, every
/// track armed, so the record-over rule reads the clips of each tick.
@MainActor struct PlayTickBenchmark {
    static let forward = Playback.playing(Shuttle(direction: .forward, rate: .one))

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aPlayTickFitsOneFrameAtTwoHours() async throws {
        let folder = try TemporaryFolder()
        let app = AppDelegate(recordings: nil)
        let (session, peaks) = try MouseEventBenchmark.fixture()
        for (n, (zoom, framesPerPoint)) in MouseEventBenchmark.zooms.enumerated() {
            let package = folder.url.appending(path: "\(n)")
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            let (model, studio) = try await timelineModel(
                try await timelinePackage(in: package, tracks: 1, seconds: 1), app: app)
            let url = studio.url
            studio.environment.saveSession = { _, _ in url }
            try studio.edit { s throws(SessionError) in s = session }
            model.armed = Set(session.tracks.map(\.id))

            // A titled window, so the chrome has its toolbar and time display.
            let window = NSWindow(
                contentRect: NSRect(
                    x: 0, y: 0, width: 1440 + HeaderWidth.standard.points + scrollerWidth, height: 660 + scrollerWidth),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            let view = TimelineScrollView(model: model, studio: studio)
            let pane = TimelinePaneView(scroll: view)
            pane.frame = try #require(window.contentView).bounds
            window.contentView?.addSubview(pane)
            let inputs = LaneInputs(
                session: session, peaks: peaks, missingMedia: [:], marks: Marks(),
                scale: TimelineScale(framesPerPoint: framesPerPoint), laneHeight: 100)
            view.update(inputs)
            view.update(inputs)
            model.timeline.scale = inputs.scale
            let chrome = SessionChrome(model: model, window: window)
            window.orderFront(nil)
            drawNow(window)
            // The ticks here, not the display link.
            view.viewWillMove(toWindow: nil)
            try #require(window.backingScaleFactor == 2, "this display has scale \(window.backingScaleFactor)")
            try #require(view.shown.width == 1440 && view.shown.height >= 600, "\(view.shown)")
            let time = try #require(chrome.time)
            try #require(model.canRecord, "Record is possible, so the record-over rule runs")

            studio.play.playback = Self.forward
            var times: [Duration] = []
            let changes = time.textChanges
            for tick in 1...610 {
                try await Task.sleep(for: .microseconds(16_700))
                let playhead = Frames(1_000_000 + tick * 800)
                let start = ContinuousClock.now
                studio.play.playhead = playhead
                chrome.update()
                view.tick(playhead: Double(playhead.count), playback: Self.forward)
                drawNow(window)
                // The first 10 ticks are not timed (the draw after the window shows).
                if tick > 10 { times.append(ContinuousClock.now - start) }
            }
            studio.play.playback = .stopped
            let sorted = times.sorted()
            print("PlayTickBenchmark \(zoom): p50 \(sorted[300]), p95 \(sorted[570]) (target 2 ms)")
            #expect(time.textChanges - changes > 50, "the ticks reached the time display")
            expectWithinBudget(sorted[570], MouseEventBenchmark.budget, "\(zoom): p95 \(sorted[570])")
            chrome.close()
            window.close()
            await model.close()
        }
    }
}
