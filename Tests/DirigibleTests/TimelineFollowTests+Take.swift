import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Observation
import Testing
import os

@testable import DirigibleApp
@testable import DirigibleAudio

/// The follow of the record head during a take (live take view, criteria C27 to C36b, guards G3
/// to G5). The fixture is the default state of `TimelineLiveTests.take`: an empty session, fit
/// zoom (128 frames per point, 184,320 frames in view), origin 0, and a take 1 at frame 0. The
/// tests give `tick` a simulated head, as `displayTick` gives the live head.
extension TimelineFollowTests {
    typealias Lanes = TimelineLiveTests.Lanes

    func take(ticks: Bool = true) async throws -> Lanes {
        try await TimelineLiveTests.take(in: folder, app: app, ticks: ticks)
    }

    /// A take tick with the head at `frame`, then the draw.
    func tick(_ lanes: Lanes, _ frame: Double, taking: Bool = true) {
        lanes.view.tick(playhead: frame, playback: .stopped, taking: taking)
        drawNow(lanes.window)
    }

    /// The held end of a take: the next minute strictly above the head + the frames in view.
    static func heldEnd(head: Double, frames: Double) -> Frames {
        Frames((Int(head + frames) / 2_880_000 + 1) * 2_880_000)
    }

    /// The overview strip over the lanes, as in the pane of the app.
    func strip(_ lanes: Lanes) -> OverviewStrip {
        let strip = OverviewStrip(
            frame: NSRect(x: 0, y: 0, width: lanes.view.frame.width, height: OverviewGeometry.height))
        lanes.window.contentView?.addSubview(strip)
        (lanes.view.overview, strip.scrollView) = (strip, lanes.view)
        lanes.update()
        return strip
    }

    /// The take ticks at 60 Hz (800 frames each) from `from` to `to`; the turns that they made.
    @discardableResult
    func run(_ lanes: Lanes, from: Double, to: Double) -> Int {
        var turns = 0
        for head in stride(from: from, through: to, by: 800) {
            let origin = lanes.view.origin
            tick(lanes, head)
            if lanes.view.origin != origin { turns += 1 }
        }
        return turns
    }

    // MARK: C27, C28, G3

    @Test func aTakeTurnsThePageAtTheDefaultState() async throws {
        let lanes = try await take()
        let view = lanes.view
        #expect(view.framesPerPoint == 128 && view.origin == 0, "the default state: \(view.framesPerPoint)")
        var (turns, failures) = (0, [String]())

        for head in stride(from: 800.0, through: 2_880_000, by: 800) {
            let (origin, frames) = (view.origin, view.visibleFrames)
            let requested = followOrigin(
                playhead: Frames(Int(head)), origin: origin, frames: frames, direction: .forward)
            tick(lanes, head)
            if view.origin != origin {
                turns += 1
                if requested == nil || abs(head - view.origin - 0.11 * frames) > 1 {
                    failures.append("head \(head): a turn to \(view.origin), the head not at 11%")
                }
                // C28: the lanes hold the new page, and the clip view did not clamp the origin.
                if Double(view.lanes.frame.width) < (view.origin + view.visibleFrames) / view.framesPerPoint
                    || view.origin != requested
                {
                    failures.append("head \(head): origin \(view.origin) for \(requested ?? -1), \(view.lanes.frame)")
                }
            } else if requested != nil {
                failures.append("head \(head): no turn past 94%")
            }
            if head < view.origin || head >= view.origin + view.visibleFrames {
                failures.append("head \(head): out of view at \(view.origin)")
            }
        }

        #expect(turns >= 18, "\(turns) turns in 60 s")
        let passed = failures.isEmpty
        #expect(passed, "\(failures.count) failures: \(failures.prefix(4))")
        await lanes.close()
    }

    // MARK: C29

    @Test func automaticScrollOffDoesNotFollowATake() async throws {
        let lanes = try await take()
        lanes.model.timeline.follows = false

        let turns = run(lanes, from: 800, to: 2_880_000)

        #expect(turns == 0)
        #expect(lanes.view.origin == 0)
        await lanes.close()
    }

    // MARK: C30, C31

    /// The first tick (stopped) takes the state: the user scrolled away from the playhead at
    /// 1,000,000. The take starts there.
    @Test func aTakeStartShowsTheHeadOffThePage() async throws {
        let lanes = try await take(ticks: false)
        let view = lanes.view
        tick(lanes, 1_000_000, taking: false)
        #expect(view.origin == 0, "the playhead is off the page")

        tick(lanes, 1_000_000)

        #expect(abs(1_000_000 - view.origin - 0.11 * view.visibleFrames) <= 1, "\(view.origin)")
        await lanes.close()
    }

    @Test func aTakeStartEndsAHoldOfAPlay() async throws {
        let lanes = try await take(ticks: false)
        let (model, view) = (lanes.model, lanes.view)
        tick(lanes, 1_000_000, taking: false)
        model.timeline.followHeld = true

        tick(lanes, 1_000_000)

        #expect(!model.timeline.followHeld, "the take start ends the hold")
        #expect(abs(1_000_000 - view.origin - 0.11 * view.visibleFrames) <= 1, "\(view.origin)")
        let turns = run(lanes, from: 1_000_800, to: 1_500_000)
        #expect(turns >= 2, "the follow turns pages: \(turns)")
        await lanes.close()
    }

    // MARK: C32

    @Test func aUserScrollDuringATakeHoldsTheFollow() async throws {
        let lanes = try await take()
        let (model, view, studio) = (lanes.model, lanes.view, lanes.studio)
        run(lanes, from: 800, to: 480_000)

        liveScroll(view, toFrame: 0)
        let origin = view.origin
        let turns = run(lanes, from: 480_800, to: 960_000)

        #expect(studio.playback == .stopped)
        #expect(model.timeline.followHeld, "a user scroll in a take holds the follow")
        #expect(turns == 0 && view.origin == origin, "no turn while held: \(view.origin)")

        // The user scrolls to the head: the hold ends, and the follow turns pages again.
        view.scroll(toFrame: 960_000 - 0.5 * view.visibleFrames)
        tick(lanes, 960_800)
        #expect(!model.timeline.followHeld, "the head is in view again")
        #expect(run(lanes, from: 961_600, to: 1_440_000) >= 2)
        await lanes.close()
    }

    // MARK: C33

    @Test func automaticScrollOnDuringATakeShowsTheLiveHead() async throws {
        let lanes = try await take()
        let (model, view) = (lanes.model, lanes.view)
        model.timelineView = view
        model.timeline.follows = false
        run(lanes, from: 800, to: 1_000_000)
        let start = Double(lanes.studio.playhead.count)
        #expect(view.origin == 0 && start < view.visibleFrames, "the Studio playhead is in view: \(start)")

        model.run(.toggleFollow)

        #expect(abs(1_000_000 - view.origin - 0.11 * view.visibleFrames) <= 1, "\(view.origin)")
        await lanes.close()
    }

    // MARK: C34, G3, G4

    /// 5 min at 512 frames per point (737,280 frames in view), one tick per 100 ms.
    @Test func theTimelineGrowsInSteps() async throws {
        let lanes = try await take()
        let view = lanes.view
        let strip = strip(lanes)
        view.show(TimelineScale(framesPerPoint: 512), origin: 0)
        drawNow(lanes.window)
        var (widths, renders, failures) = (0, strip.renders, [String]())

        for head in stride(from: 0.0, through: 14_400_000, by: 4_800) {
            let width = view.lanes.frame.width
            tick(lanes, head)
            if view.lanes.frame.width != width { widths += 1 }
            let end = Self.heldEnd(head: head, frames: view.visibleFrames)
            let document = Viewport.documentWidth(
                end: end, rate: 48_000, scale: TimelineScale(framesPerPoint: 512), shown: Double(view.shown.width))
            if view.viewport?.end != end || Double(view.lanes.frame.width) != document
                || strip.inputs?.extent != Viewport.extent(end: end, rate: 48_000)
            {
                failures.append(
                    "head \(head): end \(String(describing: view.viewport?.end)) for \(end), \(view.lanes.frame.width)")
            }
        }
        renders = strip.renders - renders

        let passed = failures.isEmpty
        #expect(passed, "\(failures.count) failures: \(failures.prefix(4))")
        #expect(widths >= 5 && widths <= 7, "\(widths) width changes")
        #expect(renders >= 5 && renders <= 7, "\(renders) strip renders")
        await lanes.close()
    }

    // MARK: C36, C36b

    @Test func theStripShowsTheLiveHead() async throws {
        let lanes = try await take()
        let strip = strip(lanes)
        var failures: [String] = []

        for head in stride(from: 800.0, through: 480_000, by: 800) {
            tick(lanes, head)
            let end = Self.heldEnd(head: head, frames: lanes.view.visibleFrames)
            let x = OverviewGeometry(width: Double(strip.bounds.width), end: end, rate: 48_000).x(of: Frames(Int(head)))
            if abs(Double(strip.playhead.frame.minX) - x) > 0.5 {
                failures.append("head \(head): \(strip.playhead.frame.minX) for \(x)")
            }
        }

        let passed = failures.isEmpty
        #expect(passed, "\(failures.count) failures: \(failures.prefix(4))")
        await lanes.close()
    }

    /// The take start (frame 0) and the live head are both in view at 512 frames per point.
    @Test func aZoomKeyInATakeAnchorsOnTheLiveHead() async throws {
        let lanes = try await take()
        let view = lanes.view
        view.show(TimelineScale(framesPerPoint: 512), origin: 0)
        tick(lanes, 480_000)
        let x = (480_000 - view.origin) / view.framesPerPoint
        #expect(view.origin == 0 && x < Double(view.shown.width), "both in view: \(x)")

        lanes.model.timelineView = view
        lanes.model.run(.zoomIn)
        let origin = view.origin
        tick(lanes, 480_000)

        #expect(view.framesPerPoint == 256)
        #expect(abs((480_000 - origin) / view.framesPerPoint - x) <= 1, "the head x: \(x) before")
        #expect(view.origin == origin, "the next tick turns no page")
        await lanes.close()
    }

    // MARK: G5

    /// From origin 0, each turn draws the ruler once over the whole lanes in view, so the time of
    /// the new origin shows at the left edge. A tick with no turn writes no `visible`, and draws no
    /// ruler unless the lanes grow: AppKit draws the ruler at a new document width.
    @Test func aTurnInATakeRedrawsTheRulerOnce() async throws {
        let lanes = try await take()
        let (model, view) = (lanes.model, lanes.view)
        let ruler = view.ruler
        var (turns, failures) = (0, [String]())

        for head in stride(from: 800.0, through: 2_880_000, by: 800) {
            let (origin, draws, width) = (view.origin, ruler.draws, view.lanes.frame.width)
            let written = OSAllocatedUnfairLock(initialState: false)
            withObservationTracking {
                _ = model.timeline.visible
            } onChange: {
                written.withLock { $0 = true }
            }
            tick(lanes, head)
            let wrote = written.withLock { $0 }
            let drew = ruler.draws - draws
            if view.origin != origin {
                turns += 1
                let left = ruler.convert(NSPoint(x: view.shown.minX, y: 0), from: view.lanes).x
                if drew != 1 || ruler.drawnRect.minX > left || ruler.drawnRect.maxX < ruler.bounds.maxX {
                    failures.append("head \(head): \(drew) ruler draws of \(ruler.drawnRect) at a turn, left \(left)")
                }
                if !wrote { failures.append("head \(head): a turn wrote no visible") }
            } else if drew > (view.lanes.frame.width == width ? 0 : 1) || wrote {
                failures.append("head \(head): \(drew) ruler draws, visible written \(wrote) with no turn")
            }
        }

        #expect(turns >= 18, "\(turns) turns")
        let passed = failures.isEmpty
        #expect(passed, "\(failures.count) failures: \(failures.prefix(4))")
        await lanes.close()
    }
}
