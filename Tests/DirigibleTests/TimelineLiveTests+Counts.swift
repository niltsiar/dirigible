import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing
import os

@testable import DirigibleApp
@testable import DirigibleAudio

/// The counts of P3 that do not use time, in `make test`, in a real window: SwiftUI runs, so
/// `view.updates` and `model.bodyRuns` count. `LiveTakeBenchmark` has the same checks with -O.
extension TimelineLiveTests {
    /// A minute of take ticks (1,200 at 60 Hz, with a drain of each track before every third
    /// tick). Each tick draws at most once, and only the new columns; a tick with no new bins
    /// draws nothing; each tick with new bins changes the pixels of its last column. No tick
    /// runs a SwiftUI body or `updateNSView`. The zoom keeps the minute on one page: a page
    /// turn writes `timeline.visible`, a SwiftUI value (decision 0017).
    @Test func liveTickCounts() async throws {
        NSWindow.allowsAutomaticWindowTabbing = false
        let model = await app.open(try await timelinePackage(in: folder.url, tracks: 2, seconds: 2))
        let studio = try #require(await model.opened() ? model.studio : nil)
        try await fixFreeSpace(model)
        await until("the window shows the lanes") {
            (model.timelineView?.updates ?? 0) > 0 && model.timelineView?.window != nil
        }
        let view = try #require(model.timelineView)
        let window = try #require(view.window)
        // Only the ticks of the test move the head.
        view.linkProxy?.view = nil
        let url = studio.url
        studio.environment.saveSession = { _, _ in url }
        let framesPerPoint = (1_200 * 800 / 0.8 / Double(view.shown.width)).rounded(.up)
        model.timeline.scale = TimelineScale(framesPerPoint: framesPerPoint)
        let take = try LiveTake(window: window, view: view, studio: studio, tracks: ["t1", "t2"], at: .zero)
        await until("SwiftUI gives the take session and the zoom") {
            view.source?.session == studio.session && view.framesPerPoint == framesPerPoint
        }
        take.tick()
        // A late SwiftUI update of the take start comes before the counts start. A wait for a
        // late update has no condition, so it is a time; it can only hide an update. In a probe,
        // the bodies of the take start ran in the draw of the tick, and none came in 300 ms.
        try await Task.sleep(for: .milliseconds(200))
        let (updates, bodies, origin, draws) = (view.updates, model.bodyRuns, view.origin, view.lanes.draws)
        let changed = watchLaneInputs(model, studio)
        var (failures, changes) = ([String](), 0)

        for tick in 1...1_200 {
            let result = take.step(drains: tick % 3 == 0)
            failures += result.failures
            if result.mustChange && result.changed { changes += 1 }
        }
        // SwiftUI runs its pending updates. A wait for no update has no condition, so it is a
        // time; it can only hide an update, never fail the test.
        try await Task.sleep(for: .milliseconds(200))

        #expect(failures.isEmpty, "\(failures.count) failures, \(failures.prefix(3))")
        #expect(changes == 400, "the ticks with new bins that changed their pixels: \(changes)")
        #expect(view.lanes.draws == draws + 400, "\(view.lanes.draws - draws) draws")
        #expect(view.origin == origin, "the minute stays on one page")
        #expect(view.updates == updates, "the ticks ran \(view.updates - updates) updateNSView")
        #expect(model.bodyRuns == bodies, "the ticks ran \(model.bodyRuns - bodies) SwiftUI bodies")
        #expect(!changed.withLock { $0 }, "a tick changed a lane input")
        #expect(take.sameTickTwice() == nil)
        take.close()
        await model.close()
    }

    /// P2 of `LiveTakeBenchmark.aPageTurnInATakeFitsOneFrame` on a small session: a take with 60 s
    /// of bins at 512 frames per point. Before each tick, the clock jumps to put the head at 96% of
    /// the page, so each tick turns the page. Each turn draws at most once, and the new bins
    /// change the pixels of the last column (`LiveTake.step`).
    @Test func aTurnInATakeDrawsOnceAndShowsTheNewBins() async throws {
        let (model, studio) = try await timelineModel(
            try await timelinePackage(in: folder.url, tracks: 2, seconds: 2), app: app)
        let (window, view) = standaloneLanes(model, studio)
        let take = try LiveTake(window: window, view: view, studio: studio, tracks: ["t1", "t2"], at: .zero)
        take.history(seconds: 60)
        // The SwiftUI update of the take session; the first tick takes the state, the second turns
        // the page to the head.
        view.update(laneInputs(model, studio))
        take.tick()
        take.tick()
        var failures: [String] = []

        for tick in 1...5 {
            let from = take.now
            take.now = take.clock(atHead: view.origin + 0.96 * view.visibleFrames) - LiveTake.frame
            take.drain(from: from)
            let result = take.step(drains: true)
            if !result.turned { failures.append("tick \(tick): no turn") }
            failures += result.failures
        }

        #expect(failures.isEmpty, "\(failures.count) failures, \(failures.prefix(3))")
        take.close()
        window.close()
        await model.close()
    }
}
