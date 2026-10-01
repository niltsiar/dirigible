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
        // The take start reaches SwiftUI before the counts start.
        try await Task.sleep(for: .milliseconds(200))
        let (updates, bodies, origin, draws) = (view.updates, model.bodyRuns, view.origin, view.lanes.draws)
        let changed = watchLaneInputs(model, studio)
        var (failures, changes) = ([String](), 0)

        for tick in 1...1_200 {
            let result = take.step(drains: tick % 3 == 0)
            failures += result.failures
            if result.mustChange && result.changed { changes += 1 }
        }
        // SwiftUI runs its pending updates.
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
}
