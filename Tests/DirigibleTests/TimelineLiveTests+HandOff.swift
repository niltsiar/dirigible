import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The store changes that are not an append, the hand-off, the record over, the head line, and
/// the surface guards of the live take (C16b, C18, C22 to C26, G2, G6, G7).
extension TimelineLiveTests {
    // MARK: C16b, G2

    /// The drop at a finalize error, a take start, and the hand-off: each draws the lanes in view
    /// once, and the next tick with the same epoch draws nothing. Each full draw equals a render.
    @Test func aStoreChangeRedrawsTheWholeView() async throws {
        let lanes = try await take()
        let (view, studio) = (lanes.view, lanes.studio)
        var failures: [String] = []
        func check(_ change: String, taking: Bool, head: Double = 0) throws {
            let draws = view.lanes.draws
            view.tick(playhead: head * Self.rate, playback: .stopped, taking: taking)
            drawNow(lanes.window)
            if view.lanes.draws != draws + 1 || view.lanes.drawnRect.width < view.shown.width {
                failures.append("\(change): \(view.lanes.draws - draws) draws of \(view.lanes.drawnRect)")
            }
            view.tick(playhead: head * Self.rate, playback: .stopped, taking: taking)
            drawNow(lanes.window)
            if view.lanes.draws != draws + 1 { failures.append("\(change): the same epoch drew again") }
            let wrong = try TimelineLayerTests.wrongPixels(view)
            if wrong.count > 0 { failures.append("\(change): \(wrong.count) pixels differ") }
        }
        // Two partial draws, then a full draw at the stop.
        lanes.report(0, 0.5)
        lanes.tick(0.5)
        lanes.report(0.5, 1)
        lanes.tick(1)
        #expect(try TimelineLayerTests.wrongPixels(view).count == 0, "two partial draws equal a full draw")
        lanes.stop(at: 1)

        studio.dropLiveTake()
        studio.transport = .idle
        try check("finalize error", taking: false)

        try studio.edit { s throws(SessionError) in
            try s.setRecording(
                Recording(take: 2, playheadFrame: 96_000, takeStartHostTimeNanos: Self.host, armedTracks: ["t1"]))
        }
        studio.live.tracks = ["t1": LivePeaks(origin: 96_000, startHostNanos: Self.host, rate: 48_000)]
        studio.live.epoch += 1
        studio.liveTracks = ["t1": LiveTrack(state: .recording, droppedFrames: 0, peak: 0)]
        studio.transport = .recording(take: 2)
        let draws = view.lanes.draws
        lanes.tick(2)
        #expect(view.lanes.draws == draws, "the take start waits for the session of SwiftUI")
        lanes.update()
        try check("take start", taking: true, head: 2)

        lanes.report(0, 1)
        lanes.tick(3)
        lanes.stop(at: 3)
        try lanes.handOff(seconds: 1, at: 2)
        let before = view.lanes.draws
        view.tick(playhead: 0, playback: .stopped)
        drawNow(lanes.window)
        #expect(view.lanes.draws == before, "the hand-off waits for the session of SwiftUI")
        lanes.update()
        try check("hand-off", taking: false)
        #expect(failures.isEmpty, "\(failures)")
        await lanes.close()
    }

    // MARK: C18

    @Test func theLiveRegionCoversOldClipsAndTheirLabels() async throws {
        let lanes = try await take { session in
            try session.addFile(AudioFile(id: "old", path: "old-interview.wav", layout: .mono, length: 384_000))
            try session.place(Clip(id: "c1", file: "old", start: 0, offset: 0, length: 192_000), on: "t1")
            try session.place(Clip(id: "c2", file: "old", start: 216_000, offset: 216_000, length: 168_000), on: "t1")
        }
        let peaks: [FileID: PeakState] = ["old": .ready(randomPeaks(frames: 384_000))]
        lanes.update(peaks: peaks)
        lanes.report(0, 3)
        lanes.tick(3)

        let view = lanes.view
        let window = try #require(view.lanes.surfaces.shown)
        var inputs = try #require(view.lanes.inputs)
        inputs.session = try {
            var session = inputs.session
            try session.clear(0..<384_000, on: "t1")
            return session
        }()
        let bare = OwnedPixels.render(
            inputs, window, view.lanes.palette, live: LiveLanes(lanes.studio, head: view.lanes.liveHead))
        let (first, end) = (try lanes.column(0), try lanes.column(3))
        var differ = 0
        for row in window.rows(of: 0..<1) {
            let shown = try #require(view.lanes.surfaces.frontRow(row))
            for column in first..<end where shown[column - window.pixels.columns.lowerBound] != bare.pixel(column, row)
            {
                differ += 1
            }
        }
        #expect(differ == 0, "the live region covers the old clip and its label: \(differ) pixels")
        #expect(try TimelineLayerTests.wrongPixels(view).count == 0)
        let box = try #require(view.lanes.clipFrame("c2"))
        #expect(try darkPixels(view.lanes, in: box) > 10, "the label of the clip after the head")
        await lanes.close()
    }

    // MARK: C22, C23

    /// The pixels of lane 0 from 110 pt (after the label) to the column before the end of `seconds`.
    func takePixels(_ lanes: Lanes, seconds: Double) throws -> [[UInt32]] {
        let window = try #require(lanes.view.lanes.surfaces.shown)
        let first = Int(110 * window.scale) - window.pixels.columns.lowerBound
        let end = try lanes.column(seconds) - 1 - window.pixels.columns.lowerBound
        return try window.rows(of: 0..<1).map {
            Array(try #require(lanes.view.lanes.surfaces.frontRow($0))[first..<end])
        }
    }

    /// A take of 2 s with four levels, stopped and drawn. Returns the live pixels of the take.
    func stoppedTake() async throws -> (Lanes, [[UInt32]]) {
        let lanes = try await take()
        lanes.report(0, 0.5)
        lanes.report(0.5, 1, peak: 0.9, rms: 0.4)
        lanes.report(1, 1.5, peak: 0.2, rms: 0.1)
        lanes.report(1.5, 2, peak: 0.6, rms: 0.3)
        lanes.tick(2)
        lanes.stop(at: 2)
        lanes.tick(2)
        return (lanes, try takePixels(lanes, seconds: 2))
    }

    @Test(arguments: [nil, PeakState.computing])
    func theFirstDrawAfterTheFinalizeShowsTheLiveWaveform(_ state: PeakState?) async throws {
        let (lanes, live) = try await stoppedTake()
        let view = lanes.view
        try lanes.handOff(seconds: 2, at: 2)
        let draws = view.lanes.draws
        view.tick(playhead: 2 * Self.rate, playback: .stopped)
        drawNow(lanes.window)
        #expect(view.lanes.draws == draws, "the hand-off waits for the session of SwiftUI")

        lanes.update(peaks: state.map { ["take-t1": $0] } ?? [:])
        #expect(try takePixels(lanes, seconds: 2) == live, "the first draw after the finalize")
        view.tick(playhead: 2 * Self.rate, playback: .stopped)
        drawNow(lanes.window)
        #expect(view.lanes.drawnRect.width >= view.shown.width, "G2: the epoch draws the lanes in view")
        #expect(try takePixels(lanes, seconds: 2) == live, "the clip draws the live peaks of its file")
        await lanes.close()
    }

    /// A draw that does not come from a tick (a new backing scale, a scroll, a refused retry)
    /// also waits for the session of SwiftUI at the hand-off, so it shows no old clips.
    @Test func aDrawWithNoTickWaitsForTheSessionAtTheHandOff() async throws {
        let (lanes, live) = try await stoppedTake()
        let view = lanes.view
        try lanes.handOff(seconds: 2, at: 2)
        let draws = view.lanes.draws
        view.lanes.needsDisplay = true
        drawNow(lanes.window)
        #expect(view.lanes.draws == draws, "a draw with no tick did not wait for the session of SwiftUI")

        lanes.update(peaks: ["take-t1": .computing])
        drawNow(lanes.window)
        #expect(view.lanes.draws > draws, "the session of SwiftUI did not draw")
        #expect(try takePixels(lanes, seconds: 2) == live, "the draw after the session shows the live peaks")
        await lanes.close()
    }

    @Test func readyPeaksReplaceTheLivePeaks() async throws {
        let (lanes, _) = try await stoppedTake()
        try lanes.handOff(seconds: 2, at: 2)
        lanes.update(peaks: ["take-t1": .computing])
        lanes.view.tick(playhead: 2 * Self.rate, playback: .stopped)

        lanes.update(peaks: ["take-t1": .ready(randomPeaks(frames: 96_000))])

        let view = lanes.view
        let window = try #require(view.lanes.surfaces.shown)
        let final = OwnedPixels.render(try #require(view.lanes.inputs), window, view.lanes.palette)
        let rows = window.rows(of: 0..<1)
        #expect(try rows.allSatisfy { try #require(view.lanes.surfaces.frontRow($0)) == final.row($0) })
        await lanes.close()
    }

    @Test func unavailablePeaksShowNoLiveWaveform() async throws {
        let (lanes, _) = try await stoppedTake()
        try lanes.handOff(seconds: 2, at: 2)
        lanes.update(peaks: ["take-t1": .unavailable])
        lanes.view.tick(playhead: 2 * Self.rate, playback: .stopped)
        drawNow(lanes.window)

        let rows = try #require(lanes.view.lanes.surfaces.shown).laneRows
        #expect(try lanes.runs(at: 1.5, lane: 0) == [Run(lanes.view.lanes.palette.clip, rows)])
        await lanes.close()
    }

    // MARK: C24

    @Test func aFinalizeErrorRemovesTheLiveRegion() async throws {
        let lanes = try await take()
        let (view, studio) = (lanes.view, lanes.studio)
        lanes.report(0, 1)
        lanes.tick(1)
        lanes.stop(at: 1)
        lanes.tick(1)
        #expect(Self.near(try lanes.runs(at: 0.5, lane: 0), try lanes.waveform()), "the live region shows")

        studio.dropLiveTake()
        studio.transport = .idle
        view.displayTick()
        drawNow(lanes.window)

        let rows = try #require(view.lanes.surfaces.shown).laneRows
        #expect(try lanes.runs(at: 0.5, lane: 0) == [Run(view.lanes.palette.lane, rows)])
        #expect(Double(view.lanes.playhead.position.x) == Double(studio.playhead.count) / view.framesPerPoint)
        await lanes.close()
    }

    // MARK: C25, C26

    @Test func increaseContrastWidensTheHead() async throws {
        let lanes = try await take()
        let playhead = lanes.view.lanes.playhead
        lanes.view.lanes.increasesContrast = true
        #expect(playhead.bounds.width == 2)
        lanes.view.lanes.increasesContrast = false
        #expect(playhead.bounds.width == 1)
        await lanes.close()
    }

    @Test func theTimelineSaysThatItRecords() async throws {
        let lanes = try await take()
        let (view, studio) = (lanes.view, lanes.studio)
        #expect(view.lanes.accessibilityValue() as? String == L10n.takeRecording.format(1))
        lanes.stop(at: 1)
        lanes.tick(1)
        #expect(view.lanes.accessibilityValue() as? String == L10n.takeFinishing.format(1))
        studio.dropLiveTake()
        studio.transport = .idle
        view.tick(playhead: 0, playback: .stopped)
        #expect(view.lanes.accessibilityValue() == nil)
        await lanes.close()
    }

    // MARK: G6, G7

    /// 1,200 ticks at 60 Hz with a report every third tick keep the capacity: no new surface.
    @Test func aTakeMakesNoNewSurface() async throws {
        let lanes = try await take()
        for tick in 1...1_200 {
            let now = Double(tick) / 60
            if tick % 3 == 0 { lanes.report(now - 0.15, now - 0.1) }
            lanes.tick(now)
        }
        #expect(lanes.view.lanes.surfaces.made <= 4, "\(lanes.view.lanes.surfaces.made) surfaces")
        await lanes.close()
    }

    @Test func aRefusedLiveDrawDrawsAtTheNextFrame() async throws {
        let lanes = try await take(onScreen: true)
        let view = lanes.view
        for step in 1...4 {
            lanes.report(Double(step - 1) * 0.25, Double(step) * 0.25)
            lanes.tick(Double(step) * 0.25)
        }
        let held = try await TimelineLayerTests.holdOnScreen(view, lanes.window)
        let surfaces = view.lanes.surfaces
        let draws = view.lanes.draws

        surfaces.refusesNewSurfaces = true
        lanes.report(1, 1.5)
        lanes.tick(1.5)
        #expect(view.lanes.draws == draws, "the refused live draw draws nothing")
        surfaces.refusesNewSurfaces = false
        for layer in held { layer.removeFromSuperlayer() }
        await until(limit: .seconds(5), "the next frame draws the live columns") {
            drawNow(lanes.window)
            return view.lanes.draws > draws
        }

        #expect(Self.near(try lanes.runs(at: 1.25, lane: 0), try lanes.waveform()))
        #expect(try TimelineLayerTests.wrongPixels(view).count == 0)
        for layer in held { layer.removeFromSuperlayer() }
        await lanes.close()
    }
}

@MainActor extension TimelineLiveTests.Lanes {
    /// The hand-off of a finalize that succeeds: a take clip of the file `take-<track>` of
    /// `seconds` on each armed track, from frame 0, and the playhead at the clip end. Then the
    /// transport is idle. SwiftUI does not have the new session yet.
    func handOff(seconds: Double, at end: Double) throws {
        var finalized = studio.session
        let armed = finalized.recording?.armedTracks ?? []
        try finalized.setRecording(nil)
        let length = Frames(Int(seconds * TimelineLiveTests.rate))
        for track in armed {
            let file = FileID("take-\(track.rawValue)")
            try finalized.addFile(AudioFile(id: file, path: "\(file.rawValue).wav", layout: .mono, length: length))
            try finalized.place(
                Clip(id: ClipID(file.rawValue), file: file, start: 0, offset: 0, length: length), on: track)
        }
        studio.handOffLive(finalized)
        studio.transport = .idle
        try studio.edit { s throws(SessionError) in s = finalized }
        _ = end
    }
}
