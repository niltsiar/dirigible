import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Observation
import Testing
import os

@testable import DirigibleApp
@testable import DirigibleAudio

/// Live take view P1, P2, and P6 with -O (`make bench FILTER=LiveTakeBenchmark`): a display tick
/// of a take and a page turn in a take are 16 ms p95 or less, and a 60 s width step and the
/// hand-off are 32 ms or less each. 1440 x 600 pt of lanes at scale 2 under the overview strip.
/// Fixture (a): the 2 h fixture of `MouseEventBenchmark`, its 6 tracks armed, a take at 2:00:00
/// with 3 h of bins (216,000 per track). Fixture (b): the default state, 6 empty tracks at the
/// closest zoom. One tick per 16.7 ms, and a drain of each track before every third tick.
@MainActor struct LiveTakeBenchmark {
    #if DEBUG
        static let oneOffBudget = Duration.milliseconds(200)
    #else
        static let oneOffBudget = Duration.milliseconds(32)
    #endif
    static let tracks = (1...6).map { TrackID("t\($0)") }
    static let takeStart = Frames(MouseEventBenchmark.frames)
    /// The fit of the head after the 3 h history: 864,000,000 frames + 2% in 1440 pt.
    static let fit = Double(MouseEventBenchmark.frames + 10_800 * 48_000) * 1.02 / 1440

    /// The lanes of `session` on screen at `framesPerPoint`, with a take at `start` that has
    /// `history` seconds of bins, after its first two ticks.
    static func lanes(
        _ session: Session, _ peaks: [FileID: PeakState], framesPerPoint: Double, at start: Frames, history: Int,
        app: AppDelegate, folder: URL
    ) async throws -> (LiveTake, SessionWindow, LaneInputs) {
        let (window, view, model, drawn) = try await MouseEventBenchmark.lanesAndInputs(
            session, peaks, framesPerPoint: framesPerPoint, app: app, folder: folder)
        var inputs = drawn
        let studio = try #require(view.studio)
        try #require(window.backingScaleFactor == 2, "this display has scale \(window.backingScaleFactor)")
        try #require(view.shown.width == 1440 && view.shown.height >= 600, "\(view.shown)")
        let take = try LiveTake(window: window, view: view, studio: studio, tracks: tracks, at: start)
        take.history(seconds: history)
        // The SwiftUI update of the take session.
        inputs.session = studio.session
        view.update(inputs)
        // The first tick only takes the state; the second turns the page to the head.
        take.tick()
        take.tick()
        return (take, model, inputs)
    }

    static func report(_ name: String, _ sorted: [Duration]) {
        let p95 = sorted[sorted.count * 95 / 100]
        print("LiveTakeBenchmark \(name): p50 \(sorted[sorted.count / 2]), p95 \(p95)")
        #expect(p95 <= MouseEventBenchmark.budget, "\(name): p95 \(p95)")
    }

    /// P1 and P3: 600 timed ticks per case (1,200 at fit), with the P3 checks of each tick. At
    /// fit, no page turns in the timed ticks, so no tick may change a lane input of SwiftUI.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aTakeTickFitsOneFrame() async throws {
        let folder = try TemporaryFolder()
        let app = AppDelegate(recordings: nil)
        let (session, peaks) = try MouseEventBenchmark.fixture()
        var empty = Session(sampleRate: 48_000)
        for track in Self.tracks { try empty.addTrack(track, name: track.rawValue, layout: .mono) }
        let cases: [(String, Session, Double, Frames, Int, Int)] = [
            ("tick, 2 h + 3 h take, fit", session, Self.fit, Self.takeStart, 10_800, 1_200),
            ("tick, 2 h + 3 h take, 512", session, 512, Self.takeStart, 10_800, 600),
            ("tick, 2 h + 3 h take, closest", session, 128, Self.takeStart, 10_800, 600),
            ("tick, default state, closest", empty, 128, .zero, 0, 600),
        ]
        for (n, (name, session, framesPerPoint, start, history, count)) in cases.enumerated() {
            let package = folder.url.appending(path: "\(n)")
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            let (take, model, _) = try await Self.lanes(
                session, n < 3 ? peaks : [:], framesPerPoint: framesPerPoint, at: start, history: history, app: app,
                folder: package)
            try #require(take.view.framesPerPoint == framesPerPoint, "\(name): \(take.view.framesPerPoint)")
            var (times, failures, checked, turns) = ([Duration](), [String](), 0, 0)
            var watch: OSAllocatedUnfairLock<Bool>?
            for tick in 1...count + 10 {
                if tick == 11 { watch = watchLaneInputs(model, take.studio) }
                try await Task.sleep(for: .microseconds(16_700))
                let result = take.step(drains: tick % 3 == 0)
                // The first 10 ticks are not timed (the draw after the window shows, the first turn).
                guard tick > 10 else { continue }
                if !result.stepped { times.append(result.time) }
                failures += result.failures
                if result.mustChange { checked += 1 }
                if result.turned { turns += 1 }
            }
            if let error = take.sameTickTwice() { failures.append(error) }
            print("LiveTakeBenchmark \(name): \(checked) ticks changed new columns, \(turns) turns")
            #expect(failures.isEmpty, "\(name): \(failures.count) failures, \(failures.prefix(3))")
            #expect(checked >= (n == 0 ? 1 : count / 3), "\(name): \(checked) ticks with new columns")
            if n == 0 {
                #expect(turns == 0, "\(name): the minute has no page turn")
                #expect(watch?.withLock { $0 } == false, "\(name): a tick changed a lane input")
            }
            Self.report(name, times.sorted())
            take.close()
            take.window.close()
            await model.close()
        }
    }

    /// P2: 120 page turns in a take, one per frame, at 512 frames per point on fixture (a).
    /// Before each timed tick the clock jumps to put the head at 96% of the page, and one span
    /// per track covers the jump. A tick with a width step is not timed (P6).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aPageTurnInATakeFitsOneFrame() async throws {
        let folder = try TemporaryFolder()
        let (session, peaks) = try MouseEventBenchmark.fixture()
        let (take, model, _) = try await Self.lanes(
            session, peaks, framesPerPoint: 512, at: Self.takeStart, history: 10_800,
            app: AppDelegate(recordings: nil), folder: folder.url)
        let view = take.view
        var (times, failures, ticks) = ([Duration](), [String](), 0)
        while times.count < 120, ticks < 400 {
            ticks += 1
            let from = take.now
            take.now = take.clock(atHead: view.origin + 0.96 * view.visibleFrames) - LiveTake.frame
            take.drain(from: from)
            try await Task.sleep(for: .microseconds(16_700))
            let result = take.step(drains: true)
            if !result.turned { failures.append("tick \(ticks): no turn") }
            failures += result.failures
            if ticks > 10, !result.stepped { times.append(result.time) }
        }
        #expect(failures.isEmpty, "turns: \(failures.count) failures, \(failures.prefix(3))")
        try #require(times.count == 120, "\(times.count) turns with no width step in \(ticks) ticks")
        Self.report("turn, 2 h + 3 h take, 512", times.sorted())
        take.close()
        take.window.close()
        await model.close()
    }

    /// P6: 20 ticks of a 60 s width step, and 20 hand-offs, at fit zoom on fixture (a) with the
    /// 3 h take in view (Automatic Scroll off, the head at 80% of the page). A width step is the
    /// tick that sets the new lanes width and renders the strip. A hand-off is the session
    /// change, the SwiftUI update, the full draw of the new epoch, and the strip render.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func theOneOffTicksOfATakeFitTwoFrames() async throws {
        let folder = try TemporaryFolder()
        let (session, peaks) = try MouseEventBenchmark.fixture()
        let (take, model, inputs) = try await Self.lanes(
            session, peaks, framesPerPoint: Self.fit, at: Self.takeStart, history: 10_800,
            app: AppDelegate(recordings: nil), folder: folder.url)
        let (view, studio) = (take.view, take.studio)
        model.timeline.follows = false
        // The whole take in view, and room for the 20 steps after the head.
        let origin = (take.head - 0.8 * view.visibleFrames).rounded()
        view.scroll(toFrame: origin)
        take.tick()
        try #require(view.origin == origin && view.framesPerPoint == Self.fit, "\(view.origin)")

        var (steps, failures) = ([Duration](), [String]())
        for _ in 0..<20 {
            let from = take.now
            take.now += 60_000_000_000 - LiveTake.frame
            take.drain(from: from)
            try await Task.sleep(for: .microseconds(16_700))
            let result = take.step(drains: true)
            if !result.stepped { failures.append("head \(take.head): no width step") }
            failures += result.failures
            steps.append(result.time)
        }
        let step = try #require(steps.max())
        print("LiveTakeBenchmark width step, fit: max \(step)")
        #expect(failures.isEmpty, "width steps: \(failures.prefix(3))")
        #expect(step <= Self.oneOffBudget, "width step: max \(step)")

        let bins = studio.live.tracks
        failures = []
        var handOffs: [Duration] = []
        for event in 1...20 {
            // The stop, untimed: the head freezes, and the lanes draw the finalize.
            studio.transport = .finalizing(take: event)
            studio.live.stopHostNanos = take.now
            take.tick()
            let head = take.head
            var finalized = studio.session
            try finalized.setRecording(nil)
            let length = Frames(Int(head)) - Self.takeStart
            for track in Self.tracks {
                let file = FileID("take\(event)-\(track.rawValue)")
                try finalized.addFile(AudioFile(id: file, path: "\(file.rawValue).wav", layout: .mono, length: length))
                try finalized.place(
                    Clip(id: ClipID(file.rawValue), file: file, start: Self.takeStart, offset: 0, length: length),
                    on: track)
            }
            var shown = inputs
            shown.session = finalized
            let draws = view.lanes.draws
            try await Task.sleep(for: .microseconds(16_700))

            let start = ContinuousClock.now
            studio.handOffLive(finalized)
            studio.transport = .idle
            try studio.edit { s throws(SessionError) in s = finalized }
            view.update(shown)
            view.tick(playhead: head, playback: .stopped)
            drawNow(take.window)
            handOffs.append(ContinuousClock.now - start)

            if view.lanes.draws != draws + 1 || view.lanes.drawnRect.width < view.shown.width {
                failures.append("hand-off \(event): \(view.lanes.draws - draws) draws of \(view.lanes.drawnRect)")
            }
            // The next take, untimed: the session of the fixture, and the same 3 h of bins.
            try studio.edit { s throws(SessionError) in s = session }
            try LiveTake.begin(studio, tracks: Self.tracks, at: Self.takeStart, take: event + 1)
            studio.live.tracks = bins
            var next = inputs
            next.session = studio.session
            view.update(next)
            take.tick()
        }
        let handOff = try #require(handOffs.max())
        print("LiveTakeBenchmark hand-off, fit: max \(handOff)")
        #expect(failures.isEmpty, "hand-offs: \(failures.prefix(3))")
        #expect(handOff <= Self.oneOffBudget, "hand-off: max \(handOff)")
        take.close()
        take.window.close()
        await model.close()
    }
}
