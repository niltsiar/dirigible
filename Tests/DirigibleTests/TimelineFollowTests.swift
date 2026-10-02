import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Observation
import Testing
import os

@testable import DirigibleApp
@testable import DirigibleAudio

/// The lane pixels change only when a drawn input changes, and the follow turns pages (decision
/// 0017, timeline-view criteria 10, 14, and 24). The lanes are 1440 pt wide at 512 frames per
/// point: 737,280 frames in view.
@Suite(.serialized) @MainActor struct TimelineFollowTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws { folder = try TemporaryFolder() }

    func lanes(seconds: Int = 60) async throws -> (SessionWindow, Studio, NSWindow, TimelineScrollView) {
        let (model, studio) = try await timelineModel(
            try await timelinePackage(in: folder.url, tracks: 2, seconds: seconds), app: app)
        let (window, view) = standaloneLanes(model, studio)
        return (model, studio, window, view)
    }

    static let forward = Playback.playing(Shuttle(direction: .forward, rate: .one))

    /// Criterion 10: 1800 ticks at 60 Hz and 1x from frame 0 turn the page twice, at the first
    /// tick past 94% of each page, and only a page turn draws.
    @Test func aTickThatDoesNotTurnThePageDrawsNothing() async throws {
        let (model, _, lanesWindow, view) = try await lanes()
        var turns: [Double] = []
        var drawsWithNoTurn = 0
        var drawsAtTurns = 0

        for tick in 0...1800 {
            let (origin, draws) = (view.origin, view.lanes.draws)
            view.tick(playhead: Double(tick * 800), playback: Self.forward)
            drawNow(lanesWindow)
            if view.origin != origin {
                turns.append(view.origin)
                drawsAtTurns += view.lanes.draws - draws
            } else {
                drawsWithNoTurn += view.lanes.draws - draws
            }
        }

        #expect(turns.count == 2, "\(turns)")
        #expect(turns.first.map { abs($0 - 612_499) <= 512 } == true, "\(turns)")
        #expect(turns.last.map { abs($0 - 1_224_499) <= 512 } == true, "\(turns)")
        #expect(drawsWithNoTurn == 0)
        #expect(drawsAtTurns >= 2, "a page turn draws the new page")
        lanesWindow.close()
        await model.close()
    }

    /// Timeline-scroll criterion 4: a user scroll of 20 pt draws only its new columns, also after
    /// page turns.
    @Test func aSmallScrollDrawsOnlyTheNewColumns() async throws {
        let (model, _, lanesWindow, view) = try await lanes(seconds: 200)
        view.tick(playhead: 0, playback: Self.forward)
        for _ in 0..<6 {
            view.tick(playhead: view.origin + 0.95 * view.visibleFrames, playback: Self.forward)
            drawNow(lanesWindow)
            // Frees the main actor for the other suites.
            await Task.yield()
        }
        let draws = view.lanes.draws

        view.scroll(toFrame: view.origin + 20 * view.framesPerPoint)
        drawNow(lanesWindow)

        #expect(view.lanes.draws == draws + 1)
        #expect(view.lanes.drawnRect.width <= 22, "\(view.lanes.drawnRect)")
        lanesWindow.close()
        await model.close()
    }

    /// Criterion 14: a user scroll during play holds the follow, and the play goes on.
    @Test func aUserScrollDuringPlayHoldsTheFollowAndThePlayGoesOn() async throws {
        let (model, studio, lanesWindow, view) = try await lanes()
        studio.environment.playerOutput = .offline
        await studio.perform(.seek(.start))
        await studio.perform(.playStop)
        view.tick(playhead: 0, playback: studio.playback)

        liveScroll(view, toFrame: 500_000)
        let origin = view.origin
        view.tick(playhead: origin + view.visibleFrames + 10_000, playback: studio.playback)

        #expect(model.timeline.followHeld)
        #expect(view.origin == origin, "no page turn during the hold")
        #expect(studio.playback == Self.forward, "the play goes on")
        await studio.perform(.playStop)
        lanesWindow.close()
        await model.close()
    }

    /// Criterion 14: a seek to a frame off the page shows it at 11%.
    @Test func aSeekOffScreenTurnsThePage() async throws {
        let (model, _, lanesWindow, view) = try await lanes()
        view.tick(playhead: 0, playback: .stopped)

        view.tick(playhead: 2_000_000, playback: .stopped)

        #expect(abs(view.origin - 1_918_899) <= 512, "\(view.origin)")
        lanesWindow.close()
        await model.close()
    }

    /// Criterion 24: equal inputs and playhead moves draw nothing.
    @Test func anUpdateWithEqualInputsDrawsNothing() async throws {
        let (model, studio, lanesWindow, view) = try await lanes()
        view.tick(playhead: 0, playback: .stopped)
        let draws = view.lanes.draws

        for _ in 0..<100 { view.update(laneInputs(model, studio)) }
        for seek in 1...30 { view.tick(playhead: Double(seek * 10_000), playback: .stopped) }
        for _ in 0..<10 {
            view.needsLayout = true
            lanesWindow.layoutIfNeeded()
        }
        drawNow(lanesWindow)

        #expect(view.lanes.draws == draws)
        #expect(view.origin == 0)
        lanesWindow.close()
        await model.close()
    }

    @Test func aMarksChangeDrawsOnce() async throws {
        let (model, studio, lanesWindow, view) = try await lanes()
        let draws = view.lanes.draws

        view.update(laneInputs(model, studio, marks: Marks(inPoint: 1000, outPoint: 50_000, tracks: ["t1"])))
        drawNow(lanesWindow)

        #expect(view.lanes.draws == draws + 1)
        lanesWindow.close()
        await model.close()
    }

    @Test func aBackingScaleChangeDrawsOnce() async throws {
        let (model, _, lanesWindow, view) = try await lanes()
        let draws = view.lanes.draws

        view.lanes.viewDidChangeBackingProperties()
        drawNow(lanesWindow)

        #expect(view.lanes.draws == draws + 1)
        lanesWindow.close()
        await model.close()
    }

    /// Criterion 24: a play of 1 s (about 30 polls) runs no `updateNSView` in a real window. SwiftUI
    /// also skips `updateNSView` for equal inputs, so the test also tracks the reads of the lane
    /// inputs: no poll changes them. With the macOS setting "prefer tabs: always", a window of a
    /// parallel test joins the tab group of this window and resizes it; the new width writes
    /// `timeline.visible`. So the window of this test opens with no automatic tabbing.
    @Test func aPlayRunsNoUpdateNSView() async throws {
        NSWindow.allowsAutomaticWindowTabbing = false
        let window = await app.open(try await timelinePackage(in: folder.url, tracks: 2, seconds: 2, audio: true))
        let studio = try #require(await window.opened() ? window.studio : nil)
        await until("the window shows the lanes") { (window.timelineView?.updates ?? 0) > 0 }
        let view = try #require(window.timelineView)
        studio.environment.playerOutput = .offline
        await studio.perform(.seek(.start))
        await studio.perform(.playStop)
        let updates = view.updates
        let changed = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = laneInputs(window, studio, laneHeight: 100)
        } onChange: {
            changed.withLock { $0 = true }
        }

        try await Task.sleep(for: .seconds(1))

        #expect(view.updates == updates)
        #expect(!changed.withLock { $0 }, "a poll changed a lane input")
        #expect(studio.playback == Self.forward, "the play goes on")
        await studio.perform(.playStop)
        await window.close()
    }
}
