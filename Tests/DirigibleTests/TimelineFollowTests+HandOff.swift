import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The end of a take keeps the view (live take view, C35): the hand-off and a finalize error are
/// not a seek, a Retry is not a take start, and a navigation input drops the held end.
extension TimelineFollowTests {
    // MARK: C35

    /// Ticks from `from` to `seconds`, the stop, and one tick of the frozen head. A take of 10 s
    /// at the default state turns the page 3 times, and the right edge of the view (644,045)
    /// is then past the width of 10 s, the shortest timeline.
    func recordAndStop(_ lanes: Lanes, from: Double = 800, seconds: Double = 10) {
        run(lanes, from: from, to: seconds * 48_000)
        lanes.stop(at: seconds)
        tick(lanes, seconds * 48_000)
    }

    @Test func theViewStaysAtTheHandOff() async throws {
        let lanes = try await take()
        let view = lanes.view
        recordAndStop(lanes)
        let origin = view.origin
        try #require(origin > 0, "a turn in the take")
        let session = Viewport.documentWidth(
            end: 480_000, rate: 48_000, scale: view.lanes.inputs!.scale, shown: Double(view.shown.width))
        #expect(Double(view.shown.maxX) > session, "the right edge is past the width of the session")

        try lanes.handOff(seconds: 10, at: 10)
        tick(lanes, 480_000, taking: false)
        lanes.update()
        tick(lanes, 480_000, taking: false)

        #expect(view.origin == origin, "\(view.origin) after the hand-off, \(origin) before")
        await lanes.close()
    }

    @Test func theHandOffKeepsAHold() async throws {
        let lanes = try await take()
        let (model, view) = (lanes.model, lanes.view)
        run(lanes, from: 800, to: 480_000)
        view.scroll(toFrame: 0)
        view.userScrolled()
        recordAndStop(lanes, from: 480_800, seconds: 12)
        #expect(model.timeline.followHeld && view.origin == 0, "a hold at the stop")

        try lanes.handOff(seconds: 12, at: 12)
        tick(lanes, 576_512, taking: false)
        lanes.update()
        tick(lanes, 576_512, taking: false)

        #expect(model.timeline.followHeld, "the hand-off keeps the hold")
        #expect(view.origin == 0)
        await lanes.close()
    }

    /// The frozen head at 93% of the view, the clip end at 95%: a seek there would turn the page.
    @Test func theHandOffDoesNotTurnThePage() async throws {
        let lanes = try await take()
        let (model, view) = (lanes.model, lanes.view)
        let frames = view.visibleFrames
        tick(lanes, 0.93 * frames)
        lanes.stop(at: 0.93 * frames / 48_000)
        tick(lanes, 0.93 * frames)

        try lanes.handOff(seconds: 0.95 * frames / 48_000, at: 0)
        tick(lanes, 0.95 * frames, taking: false)
        lanes.update()
        tick(lanes, 0.95 * frames, taking: false)

        #expect(view.origin == 0, "\(view.origin)")
        #expect(!model.timeline.followHeld)
        await lanes.close()
    }

    /// A finalize error: the session has no take, so its width is the view; the view stays.
    @Test func aFinalizeErrorKeepsTheView() async throws {
        let lanes = try await take()
        let (model, view, studio) = (lanes.model, lanes.view, lanes.studio)
        recordAndStop(lanes)
        let (origin, held) = (view.origin, model.timeline.followHeld)
        try #require(origin > 0, "a turn in the take")

        studio.dropLiveTake()
        studio.transport = .idle
        tick(lanes, Double(studio.playhead.count), taking: false)
        tick(lanes, Double(studio.playhead.count), taking: false)

        #expect(view.origin == origin, "\(view.origin) after the error, \(origin) before")
        #expect(model.timeline.followHeld == held)
        await lanes.close()
    }

    /// A Retry finalizes with no live head: `displayTick` gives no take, so no take start.
    @Test func aRetryIsNotATakeStart() async throws {
        let lanes = try await take()
        let (model, view, studio) = (lanes.model, lanes.view, lanes.studio)
        recordAndStop(lanes)
        studio.dropLiveTake()
        studio.transport = .idle
        tick(lanes, Double(studio.playhead.count), taking: false)
        let (origin, held, width) = (view.origin, model.timeline.followHeld, view.lanes.frame.width)

        studio.transport = .finalizing(take: 1)
        #expect(studio.liveHead() == nil, "a retry has no live head")
        view.displayTick()
        drawNow(lanes.window)

        #expect(view.origin == origin && origin > 0, "\(view.origin)")
        #expect(model.timeline.followHeld == held)
        #expect(view.lanes.frame.width == width, "the held end stays")
        await lanes.close()
    }

    @Test func zoomToSessionDropsTheHeldEnd() async throws {
        let lanes = try await take()
        let view = lanes.view
        recordAndStop(lanes)
        try lanes.handOff(seconds: 10, at: 10)
        tick(lanes, 480_000, taking: false)
        lanes.update()
        try #require(view.origin > 0)

        view.navigate(.fitSession)

        #expect(view.viewport?.end == 480_000)
        let width = Viewport.documentWidth(
            end: 480_000, rate: 48_000, scale: view.lanes.inputs!.scale, shown: Double(view.shown.width))
        #expect(Double(view.lanes.frame.width) == width, "\(view.lanes.frame.width) for \(width)")
        await lanes.close()
    }
}
