import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Observation
import Testing
import os

@testable import DirigibleApp
@testable import DirigibleAudio

/// A take in progress on the lanes of `view`, with a test clock in host nanoseconds (live take
/// view, P1 to P3 and P6). The spans go through the seam that `apply(.levels)` calls, and the
/// head comes from `liveHead(atHostNanos:)` at the clock, as `displayTick` gives it.
@MainActor final class LiveTake {
    static let host = TimelineLiveTests.host
    /// One 60 Hz display frame and one drain of a device writer, in nanoseconds.
    static let frame: UInt64 = 16_666_667
    static let drain: UInt64 = 50_000_000

    let window: NSWindow
    let view: TimelineScrollView
    let studio: Studio
    let tracks: [TrackID]
    /// The session frame of the take start.
    let start: Frames
    /// The test clock.
    var now: UInt64
    private var drains = 0

    /// The facts of one tick, read after the clock stops.
    struct Tick {
        var time: Duration
        var turned: Bool
        /// The lanes took a new width (a 60 s step): P6 budgets this tick, not P1 or P2.
        var stepped: Bool
        /// The tick changed the front pixels of lane 0 in the column of its last frame.
        var changed: Bool
        /// The column of the last frame is after the columns of the last live draw, so a tick
        /// with new bins must change it.
        var mustChange: Bool
        var failures: [String]
    }

    /// Starts take `take` at `start` with `tracks` armed and the clock at the take start.
    init(window: NSWindow, view: TimelineScrollView, studio: Studio, tracks: [TrackID], at start: Frames, take: Int = 1)
        throws
    {
        (self.window, self.view, self.studio, self.tracks, self.start) = (window, view, studio, tracks, start)
        now = Self.host
        try Self.begin(studio, tracks: tracks, at: start, take: take)
    }

    /// The store state of a take start, as `Studio.beginLive` sets it, with no device.
    static func begin(_ studio: Studio, tracks: [TrackID], at start: Frames, take: Int) throws {
        try studio.edit(ripple: false) { s throws(SessionError) in
            try s.setRecording(
                Recording(take: take, playheadFrame: start, takeStartHostTimeNanos: host, armedTracks: tracks))
        }
        studio.live.tracks = Dictionary(
            uniqueKeysWithValues: tracks.map { ($0, LivePeaks(origin: start, startHostNanos: host, rate: 48_000)) })
        studio.live.arms = Dictionary(uniqueKeysWithValues: tracks.enumerated().map { ($0 + 1, $1) })
        studio.live.stopHostNanos = nil
        studio.live.epoch += 1
        studio.liveTracks = Dictionary(
            uniqueKeysWithValues: tracks.map { ($0, LiveTrack(state: .recording, droppedFrames: 0, peak: 0)) })
        studio.transport = .recording(take: take)
    }

    /// One drain of each track: the span from `from` to the clock, at a level that changes with
    /// each drain and track.
    func drain(from: UInt64? = nil) {
        drains += 1
        let span = (from ?? now - Self.drain)..<now
        for (n, track) in tracks.enumerated() {
            let peak = Float(0.2 + 0.07 * Double((drains + n) % 10))
            studio.addLive(
                track: track, level: ArmLevel(peak: peak, rms: peak / 2, written: span), latencyNanos: 0, now: now)
        }
    }

    /// The bins of `seconds` of audio from the clock on, one span per minute, and the clock after them.
    func history(seconds: Int) {
        for _ in 0..<seconds / 60 {
            let from = now
            now += 60_000_000_000
            drain(from: from)
        }
    }

    /// The record head at the clock.
    var head: Double { Double(studio.liveHead(atHostNanos: now)?.count ?? 0) }

    /// The clock at the record head `frame`.
    func clock(atHead frame: Double) -> UInt64 { Self.host + UInt64((frame - Double(start.count)) / 48_000 * 1e9) }

    /// The tick of the clock with no other change, and its draw.
    func tick() {
        view.tick(playhead: head, playback: .stopped, taking: true)
        drawNow(window)
    }

    /// The pixels of lane 0 in the pixel column of `frame` on the front surface, every 8th row.
    func pixels(at frame: Double) -> [UInt32?] {
        guard let shown = view.lanes.surfaces.shown else { return [] }
        let column = Int((frame / view.framesPerPoint * shown.scale).rounded(.down))
        return stride(from: shown.rows(of: 0..<1).lowerBound, to: shown.rows(of: 0..<1).upperBound, by: 8).map {
            view.lanes.surfaces.pixel(column: column, row: $0)
        }
    }

    /// One display tick after the clock moves `advance`: the timed part is the drain of each
    /// track (when `drains`), the head, the tick, and the draw. The checks of P3: at most 1 draw;
    /// on a tick with new bins and no turn, a drawn width of at most the head move since the
    /// last live draw + the columns of the new bins + 2 pt (F1); no draw on a tick with no new
    /// bins and no turn.
    func step(drains: Bool, advance: UInt64 = frame) -> Tick {
        now += advance
        let lanes = view.lanes
        let (draws, width, origin, version) = (lanes.draws, lanes.frame.width, view.origin, studio.liveVersion)
        let fpp = view.framesPerPoint
        let expected = head
        let last = lanes.liveHead.map { Double($0.count) } ?? expected
        let before = pixels(at: expected - 1)

        let began = ContinuousClock.now
        if drains { drain() }
        view.tick(playhead: head, playback: .stopped, taking: true)
        drawNow(window)
        let time = ContinuousClock.now - began

        let scale = lanes.surfaces.shown?.scale ?? 2
        let fresh = studio.liveVersion != version
        let turned = view.origin != origin
        let stepped = lanes.frame.width != width
        let drew = lanes.draws - draws
        let changed = pixels(at: expected - 1) != before
        let mustChange = fresh && Int((expected - 1) / fpp * scale) >= Int((last / fpp * scale).rounded(.up))
        var failures: [String] = []
        if drew > 1 { failures.append("head \(expected): \(drew) draws") }
        if !turned, !stepped {
            // The lowest bin of the drain starts at most one bin before its span.
            let bin = Double(48_000 / 20)
            let span = expected - Double(Self.drain) * 48_000 / 1e9
            let low = min(last, Double(start.count) + ((span - Double(start.count)) / bin).rounded(.down) * bin)
            let bound = (expected / fpp).rounded(.up) - (low / fpp).rounded(.down) + 2
            if fresh, drew != 1 || lanes.drawnRect.width > bound {
                failures.append("head \(expected): \(drew) draws, width \(lanes.drawnRect.width) > \(bound)")
            }
            if !fresh, drew != 0 { failures.append("head \(expected): a tick with no new bin drew") }
        }
        if mustChange, !changed { failures.append("head \(expected): the new bins changed no pixel") }
        return Tick(
            time: time, turned: turned, stepped: stepped, changed: changed, mustChange: mustChange, failures: failures)
    }

    /// k-c: the same tick input twice (the clock and the store do not move). The second tick
    /// draws nothing and changes no pixel. Nil when it holds.
    func sameTickTwice() -> String? {
        let first = step(drains: true)
        let draws = view.lanes.draws
        let second = step(drains: false, advance: 0)
        guard view.lanes.draws == draws, !second.changed, first.changed || !first.mustChange else {
            return "k-c: the first tick changed \(first.changed), the second drew \(view.lanes.draws - draws)"
        }
        return nil
    }

    /// The end of the take, before the window closes.
    func close() {
        studio.transport = .idle
        _ = try? studio.edit(ripple: false) { s throws(SessionError) in try s.setRecording(nil) }
    }
}

/// Tracks the reads of the lane inputs that SwiftUI makes; true after a change of one.
@MainActor func watchLaneInputs(_ model: SessionWindow, _ studio: Studio) -> OSAllocatedUnfairLock<Bool> {
    let changed = OSAllocatedUnfairLock(initialState: false)
    withObservationTracking {
        _ = laneInputs(model, studio, laneHeight: 100)
    } onChange: {
        changed.withLock { $0 = true }
    }
    return changed
}
