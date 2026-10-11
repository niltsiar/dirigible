import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import SwiftUI
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Track fader C13 (F94): one fader drag event during play on the 2 h fixture fits one 60 Hz
/// frame, p95 16 ms or less with -O (`make bench FILTER=FaderDragBenchmark`); the debug budget of
/// 100 ms is a proxy, as `MouseEventBenchmark`. An event is the slider action, the readout, and
/// `Studio.previewGain`, timed to the end of `drawNow`. The lanes do not draw: a preview is not an
/// edit. The play has no sound (the offline output). The time-free count of C11 guards the row
/// bodies (`HeaderRowTests.aFaderDragRunsNoRowBody`).
@MainActor struct FaderDragBenchmark {
    /// One new drag value for each event: -50 to +20 dB in 0.5 dB steps, with no two values in the
    /// detent at 0 dB.
    static let path: [Double] = stride(from: -50.0, through: 20, by: 0.5).filter { abs($0) >= 0.75 || $0 == 0 }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aFaderDragEventDuringPlayFitsOneFrameAtTwoHours() async throws {
        let folder = try TemporaryFolder()
        let app = AppDelegate(recordings: nil)
        let (session, peaks) = try MouseEventBenchmark.fixture()
        let (zoom, framesPerPoint) = MouseEventBenchmark.zooms[0]
        let (window, view, model) = try await MouseEventBenchmark.lanesOnScreen(
            session, peaks, framesPerPoint: framesPerPoint, app: app, folder: folder.url)
        let studio = try #require(model.studio)
        view.headers.host.rootView = AnyView(TrackHeaders(model: model, studio: studio, laneHeight: 100, selected: []))
        drawNow(window)
        try #require(window.backingScaleFactor == 2, "this display has scale \(window.backingScaleFactor)")
        studio.environment.playerOutput = .offline
        await studio.perform(.seek(.start))
        await studio.perform(.playStop)
        try #require(studio.play.player != nil && studio.playback != .stopped, "the play runs")
        let fader = try #require(faderViews(view.headers.host).first, "a fader in the first row")
        let slider = fader.slider

        slider.beginDrag()
        var times: [Duration] = []
        var changed: [Bool] = []
        for (event, dB) in Self.path.prefix(130).enumerated() {
            let (revision, draws) = (studio.play.revision, view.lanes.draws)
            try await Task.sleep(for: .microseconds(16_700))
            let start = ContinuousClock.now
            slider.doubleValue = FaderScale(start: 0).position(dB: dB)
            slider.sendAction(slider.action, to: slider.target)
            drawNow(window)
            let time = ContinuousClock.now - start
            if event >= 10 { times.append(time) }
            changed.append(slider.shown == dB && studio.play.revision == revision + 1 && view.lanes.draws == draws)
        }
        slider.endDrag()

        let failed = changed.indices.filter { !changed[$0] }
        #expect(failed.isEmpty, "C13: each event changed the readout, sent a preview, and drew no lane: \(failed)")
        let sorted = times.sorted()
        let p95 = sorted[Int(Double(sorted.count) * 0.95)]
        print(
            "FaderDragBenchmark \(zoom): p50 \(sorted[sorted.count / 2]), p95 \(p95), max \(sorted.last!),"
                + " \(sorted.count) events")
        expectWithinBudget(p95, MouseEventBenchmark.budget, "fader drag p95 \(zoom): \(p95)")
        await studio.perform(.playStop)
        window.close()
        await model.close()
    }
}
