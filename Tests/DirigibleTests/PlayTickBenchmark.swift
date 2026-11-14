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
/// track armed, so the record-over rule reads the clips of each tick. Run 9b criterion 17: the
/// loudness strip shows under the lanes, and `Studio.loudness` has a new value at each tick; its
/// texts change at least 20 times and at most 4 times for each second of the loop (the 4 Hz gate).
/// Transcript criterion P4b: a real pane at the 320 pt width shows 27 000 units of two tracks, and
/// each tick calls `transcriptTick(frame:)` in the timed block, so the budget holds the underline.
@MainActor struct PlayTickBenchmark {
    static let forward = Playback.playing(Shuttle(direction: .forward, rate: .one))

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aPlayTickFitsOneFrameAtTwoHours() async throws {
        let folder = try TemporaryFolder()
        let app = AppDelegate(recordings: nil)
        var (session, peaks) = try MouseEventBenchmark.fixture()
        // 27 000 units on two tracks, shown by a real pane at the Transcript tab (P4b).
        for track in ["t1", "t3"] as [TrackID] {
            try session.importTranscript(try TranscriptTextBenchmark.transcript(), name: "Speaker", track: track, at: 0)
        }
        for (n, (zoom, framesPerPoint)) in MouseEventBenchmark.zooms.enumerated() {
            let package = folder.url.appending(path: "\(n)")
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            let (model, studio) = try await timelineModel(
                try await timelinePackage(in: package, tracks: 1, seconds: 1), app: app)
            let url = studio.url
            studio.environment.saveSession = { _, _ in url }
            try studio.edit(ripple: false) { s throws(SessionError) in s = session }
            model.armed = Set(session.tracks.map(\.id))

            // A titled window, so the chrome has its toolbar and time display.
            let window = NSWindow(
                contentRect: NSRect(
                    x: 0, y: 0, width: 1440 + HeaderWidth.standard.points + WaveformScaleStrip.width + scrollerWidth,
                    height: 660 + scrollerWidth + LoudnessStrip.height),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            let view = TimelineScrollView(model: model, studio: studio)
            let pane = TimelinePaneView(scroll: view)
            let content = try #require(window.contentView).bounds
            pane.frame = content.divided(atDistance: LoudnessStrip.height, from: .minYEdge).remainder
            window.contentView?.addSubview(pane)
            let strip = LoudnessStrip(
                frame: content.divided(atDistance: LoudnessStrip.height, from: .minYEdge).slice)
            window.contentView?.addSubview(strip)
            model.loudnessStrip = strip
            let inputs = LaneInputs(
                session: session, peaks: peaks, missingMedia: [:], selection: .none,
                scale: TimelineScale(framesPerPoint: framesPerPoint), laneHeight: 100, range: .standard)
            view.update(inputs)
            view.update(inputs)
            model.timeline.scale = inputs.scale
            let chrome = SessionChrome(model: model, window: window)
            let scroll = TranscriptTextView.scrollView()
            scroll.frame = NSRect(x: content.width - 320, y: content.height - 600, width: 320, height: 600)
            window.contentView?.addSubview(scroll)
            let text = try #require(scroll.documentView as? TranscriptTextView)
            text.model = model
            model.transcriptFollow.pane = text
            window.orderFront(nil)
            #expect(text.begin(revision: 1))
            text.apply(await TranscriptTextView.build(session, notices: [], revision: 1))
            try #require(text.shown?.text.units.count == 27_000, "the pane shows 27 000 units")
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
            let (stripChanges, loopStart) = (strip.textChanges, ContinuousClock.now)
            for tick in 1...610 {
                try await Task.sleep(for: .microseconds(16_700))
                let playhead = Frames(1_000_000 + tick * 800)
                let start = ContinuousClock.now
                studio.play.playhead = playhead
                studio.loudness = LoudnessValues(
                    momentary: LUFS(value: -30 + Double(tick % 40) / 2),
                    shortTerm: LUFS(value: -20 + Double(tick % 30) / 10),
                    integrated: LUFS(value: -18 + Double(tick % 20) / 10), truePeak: -3 + Double(tick % 10) / 5,
                    seconds: 600 + Double(tick) / 60)
                chrome.update()
                view.tick(playhead: Double(playhead.count), playback: Self.forward)
                model.loudnessTick(studio)
                model.transcriptTick(frame: playhead)
                drawNow(window)
                // The first 10 ticks are not timed (the draw after the window shows).
                if tick > 10 { times.append(ContinuousClock.now - start) }
            }
            studio.play.playback = .stopped
            #expect(text.builds == 1 && text.replacements == 1, "the ticks built no text")
            #expect(text.underlines.count > 0, "the ticks reached the underline")
            let loop = (ContinuousClock.now - loopStart) / .seconds(1)
            let sorted = times.sorted()
            print("PlayTickBenchmark \(zoom): p50 \(sorted[300]), p95 \(sorted[570]) (target 2 ms)")
            #expect(time.textChanges - changes > 50, "the ticks reached the time display")
            let stripCount = strip.textChanges - stripChanges
            // The 4 Hz gate counts wall time; a sleep of 16.7 ms can take more, so the limit is
            // 4 for each second of the loop. With no gate the texts change at each tick (610).
            #expect(
                (20...Int(loop * 4) + 1).contains(stripCount),
                "the strip texts changed \(stripCount) times in \(loop) s")
            expectWithinBudget(sorted[570], MouseEventBenchmark.budget, "\(zoom): p95 \(sorted[570])")
            chrome.close()
            window.close()
            await model.close()
        }
    }
}
