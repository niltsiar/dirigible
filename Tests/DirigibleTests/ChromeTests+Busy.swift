import AppKit
import CoreAudio
import DirigibleCore
import Foundation
import Testing
import os

@testable import DirigibleApp
@testable import DirigibleAudio

/// The main thread during a take: it stays free for the input events and the window updates.
extension ChromeTests {
    /// The main thread during a 12.5 s take of 2 armed tracks with 64-frame device buffers (a
    /// call app can set them), in an early and a late window of 4 s: a block that a thread posts
    /// every 10 ms runs within 100 ms, the run loop is busy less than half of the time, and each
    /// main job stays at its design rate. Slow: the take runs in real time.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func theMainThreadStaysFreeDuringATakeWithSmallBuffers() async throws {
        let (model, studio, chrome) = try await open(tracks: 2)
        studio.environment.diskCheckInterval = .seconds(60)
        chrome.startTicker(every: .seconds(600))
        try studio.edit(ripple: false) { s throws(SessionError) in
            try s.setRoute(.device(uid: "duo", channels: .mono(2)), track: "t2")
        }
        model.armed = ["t1", "t2"]
        await until("the window shows the lanes") { model.timelineView?.window != nil }
        let view = try #require(model.timelineView)
        let probe = MainQueueProbe()
        probe.start()
        defer { probe.stop() }
        await model.record()
        try #require(model.canStop, "the take runs")
        await until("an input is attached") { !hal.isFree }
        let taken = ContinuousClock.now
        let stop = OSAllocatedUnfairLock(initialState: false)
        let feed = Task.detached { [hal] in await hal.stream(frames: 64, until: stop) }

        // The take runs: the display link ticks, each drain adds bins, and the head tick turns the loop.
        let first = (ticks: view.linkProxy?.ticks ?? 0, version: studio.liveVersion, turns: chrome.turns)
        await until(limit: .seconds(30), "the display link, the drains, and the head tick run") {
            (view.linkProxy?.ticks ?? 0) - first.ticks >= 30 && studio.liveVersion - first.version >= 10
                && chrome.turns - first.turns >= 5
        }
        let started = probe.read()
        print(
            String(
                format: "R2 start: heartbeat max %.1f ms, late %d of %d, longest pass %.1f ms",
                started.maxLatency * 1000, started.late, started.beats, started.longestPass * 1000))

        for (name, from) in [("early", Duration.milliseconds(500)), ("late", .milliseconds(8_500))] {
            try? await Task.sleep(until: taken + from)
            let before = (
                turns: chrome.turns, updates: view.updates, ticks: view.linkProxy?.ticks ?? 0,
                draws: view.lanes.draws, version: studio.liveVersion
            )
            probe.reset()
            let start = ContinuousClock.now
            try? await Task.sleep(for: .seconds(4))
            let seconds = (ContinuousClock.now - start) / .seconds(1)
            let measured = probe.read()
            func rate(_ count: Int) -> Double { Double(count) / seconds }
            let (turns, updates, ticks, draws, adds) = (
                rate(chrome.turns - before.turns), rate(view.updates - before.updates),
                rate((view.linkProxy?.ticks ?? 0) - before.ticks), rate(view.lanes.draws - before.draws),
                rate(studio.liveVersion - before.version)
            )
            let busy = measured.busy / seconds
            print(
                String(
                    format:
                        "R2 %@ window: heartbeat max %.1f ms, late %d of %d, busy %.0f%%, longest pass %.1f ms; "
                        + "per second: chrome turns %.1f, SwiftUI updates %.1f, display ticks %.1f, "
                        + "lane draws %.1f, live adds %.1f",
                    name, measured.maxLatency * 1000, measured.late, measured.beats, busy * 100,
                    measured.longestPass * 1000, turns, updates, ticks, draws, adds))
            #expect(measured.maxLatency < 0.1, "\(name): a main queue block waited \(measured.maxLatency) s")
            #expect(busy < 0.5, "\(name): the main run loop was busy \(busy) of the time")
            // The head tick turns the loop 10 times a second; a report changes no value that it reads.
            #expect(turns <= 20, "\(name): \(turns) chrome turns per second")
            // The live store is not observed (`LiveStore`), so a report gives SwiftUI no update.
            #expect(updates <= 1, "\(name): \(updates) SwiftUI updates of the timeline per second")
            #expect(draws <= ticks + 1, "\(name): \(draws) lane draws per second, \(ticks) ticks")
        }
        stop.withLock { $0 = true }
        let records = await feed.value
        print("R2 records: \(records) of 64 frames in \((ContinuousClock.now - taken) / .seconds(1)) s")
        await model.stop()
        await until("the finalize ends") { studio.transport == .idle }
        await model.close()
    }
}

/// Measures the main queue from a thread of its own: a heartbeat block every 10 ms and its wait,
/// and the busy time of the main run loop (from each wake to the next wait).
final class MainQueueProbe: @unchecked Sendable {
    struct Reading {
        var beats = 0
        var late = 0
        var maxLatency: Double = 0
        var busy: Double = 0
        var longestPass: Double = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: (reading: Reading(), woke: Double?.none))
    private let queue = DispatchQueue(label: "main-queue-probe")
    private var timer: DispatchSourceTimer?
    private var observer: CFRunLoopObserver?

    func start() {
        let observer = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue, true, 0
        ) { @Sendable [state] _, activity in
            let now = CACurrentMediaTime()
            state.withLock { state in
                if activity == .afterWaiting {
                    state.woke = now
                } else if let woke = state.woke {
                    state.reading.busy += now - woke
                    state.reading.longestPass = max(state.reading.longestPass, now - woke)
                    state.woke = nil
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
        timer.setEventHandler { @Sendable [state] in
            let posted = CACurrentMediaTime()
            DispatchQueue.main.async {
                let latency = CACurrentMediaTime() - posted
                state.withLock { state in
                    state.reading.beats += 1
                    if latency >= 0.1 { state.reading.late += 1 }
                    state.reading.maxLatency = max(state.reading.maxLatency, latency)
                }
            }
        }
        timer.resume()
        self.timer = timer
    }

    func reset() { state.withLock { $0.reading = Reading() } }

    /// The reading so far. A pass that is still open counts as busy up to now.
    func read() -> Reading {
        let now = CACurrentMediaTime()
        return state.withLock { state in
            var reading = state.reading
            if let woke = state.woke {
                reading.busy += now - woke
                reading.longestPass = max(reading.longestPass, now - woke)
            }
            return reading
        }
    }

    func stop() {
        timer?.cancel()
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
    }
}
