import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The live take on the lanes (live take view, criteria C14 to C26, guards G1, G2, and G6 to
/// G8). The default state: tracks `t1` and `t2` with no clip, fit zoom (the closest zoom, 128
/// frames per point, for an empty session), origin 0,
/// and a take 1 at frame 0. The tests drive `tick` with a simulated head and add the spans through
/// the seam that `apply(.levels)` calls, so no clock and no device take part.
@Suite(.serialized) @MainActor struct TimelineLiveTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws { folder = try TemporaryFolder() }

    /// The host time of the take start.
    static let host: UInt64 = 1_000_000_000_000
    static let rate = 48_000.0

    @MainActor struct Lanes {
        let model: SessionWindow
        let studio: Studio
        let window: NSWindow
        let view: TimelineScrollView

        /// One display tick of the take with the head at `seconds`, then the draw.
        func tick(_ seconds: Double) {
            view.tick(playhead: seconds * TimelineLiveTests.rate, playback: .stopped, taking: true)
            drawNow(window)
        }

        /// A report of `track` for the host span from `from` to `to` seconds after the take start.
        func report(_ from: Double, _ to: Double, track: TrackID = "t1", peak: Float = 0.5, rms: Float = 0.25) {
            // Signed: a span can start before the take start.
            func host(_ seconds: Double) -> UInt64 { UInt64(Int64(TimelineLiveTests.host) + Int64(seconds * 1e9)) }
            let span = host(from)..<host(to)
            studio.addLive(
                track: track, level: ArmLevel(peak: peak, rms: rms, written: span), latencyNanos: 0,
                now: span.upperBound)
        }

        /// The stop: the head freezes at `seconds`, and the take finalizes.
        func stop(at seconds: Double) {
            studio.transport = .finalizing(take: 1)
            studio.live.stopHostNanos = host + UInt64(seconds * 1e9)
            studio.liveTracks = [:]
        }

        /// The SwiftUI update of the lanes, at the zoom of the window.
        func update(peaks: [FileID: PeakState]? = nil) {
            var inputs = laneInputs(model, studio, selection: model.timeline.selection)
            inputs.scale = model.timeline.scale
            if let peaks { inputs.peaks = peaks }
            view.update(inputs)
            drawNow(window)
        }

        /// The pixel column of a time at the zoom of the lanes.
        func column(_ seconds: Double) throws -> Int {
            let scale = try #require(view.lanes.surfaces.shown).scale
            return Int((seconds * TimelineLiveTests.rate / view.framesPerPoint * scale).rounded(.down))
        }

        /// The colors of the pixel column at `seconds` in `lane` on the front surface, from the
        /// top, as runs.
        func runs(at seconds: Double, lane: Int) throws -> [Run] {
            let window = try #require(view.lanes.surfaces.shown)
            let column = try column(seconds)
            var runs: [Run] = []
            for row in window.rows(of: lane..<lane + 1) {
                let pixel = try #require(view.lanes.surfaces.pixel(column: column, row: row))
                if runs.last?.color == pixel { runs[runs.count - 1].count += 1 } else { runs.append(Run(pixel, 1)) }
            }
            return runs
        }

        /// The runs of a waveform column with `peak` and `rms` on the -60 dB scale, over the clip color.
        func waveform(peak: Float = 0.5, rms: Float = 0.25) throws -> [Run] {
            let rows = try #require(view.lanes.surfaces.shown).laneRows
            func height(_ value: Float) -> Int {
                Int(((20 * log10(Double(value)) + 60) / 60 * Double(rows)).rounded())
            }
            let palette = view.lanes.palette
            let (p, r) = (height(peak), height(rms))
            return [Run(palette.clip, rows - p), Run(palette.peak, p - r), Run(palette.rms, r)]
        }

        func close() async {
            studio.transport = .idle
            _ = try? studio.edit { s throws(SessionError) in try s.setRecording(nil) }
            window.close()
            await model.close()
        }
    }

    struct Run: Equatable, CustomStringConvertible {
        var color: UInt32
        var count: Int
        init(_ color: UInt32, _ count: Int) { (self.color, self.count) = (color, count) }
        var description: String { "\(String(color, radix: 16)) x\(count)" }
    }

    /// The same colors, each count within 1 pixel.
    static func near(_ runs: [Run], _ expected: [Run]) -> Bool {
        runs.count == expected.count
            && zip(runs, expected).allSatisfy { $0.color == $1.color && abs($0.count - $1.count) <= 1 }
    }

    /// The default state with `armed` armed, a take 1 that records from frame 0, and one tick at
    /// head 0. `build` adds clips to the session.
    func take(
        armed: [TrackID] = ["t1"], onScreen: Bool = false, _ build: (inout Session) throws -> Void = { _ in }
    ) async throws -> Lanes {
        try await Self.take(in: folder, app: app, armed: armed, onScreen: onScreen, build)
    }

    /// The fixture of `take` for other suites. With `ticks` false, the test gives the first tick,
    /// so its first tick with `taking` is a take start.
    static func take(
        in folder: TemporaryFolder, app: AppDelegate, armed: [TrackID] = ["t1"], onScreen: Bool = false,
        ticks: Bool = true, _ build: (inout Session) throws -> Void = { _ in }
    ) async throws -> Lanes {
        let (model, studio) = try await timelineModel(
            try await timelinePackage(in: folder.url, tracks: 1, seconds: 1), app: app)
        let url = studio.url
        studio.environment.saveSession = { _, _ in url }
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "T1", layout: .mono)
        try session.addTrack("t2", name: "T2", layout: .mono)
        try build(&session)
        try session.setRecording(
            Recording(take: 1, playheadFrame: 0, takeStartHostTimeNanos: Self.host, armedTracks: armed))
        try studio.edit { s throws(SessionError) in s = session }
        let (window, view) = standaloneLanes(model, studio, onScreen: onScreen)
        // Only the ticks of the test move the head.
        view.linkProxy?.view = nil
        let lanes = Lanes(model: model, studio: studio, window: window, view: view)
        lanes.update()
        studio.live.tracks = Dictionary(
            uniqueKeysWithValues: armed.map { ($0, LivePeaks(origin: 0, startHostNanos: Self.host, rate: 48_000)) })
        studio.live.arms = Dictionary(uniqueKeysWithValues: armed.enumerated().map { ($0 + 1, $1) })
        studio.live.epoch += 1
        studio.liveTracks = Dictionary(
            uniqueKeysWithValues: armed.map { ($0, LiveTrack(state: .recording, droppedFrames: 0, peak: 0)) })
        studio.transport = .recording(take: 1)
        if ticks { lanes.tick(0) }
        return lanes
    }

    // MARK: C14, C15, G1

    @Test func aReportAndATickDrawTheLiveColumnsAtFit() async throws {
        let lanes = try await take()
        let view = lanes.view
        // The fit of an empty session is the closest zoom: 3.84 s in view.
        #expect(view.framesPerPoint == 128 && view.origin == 0, "the default state: \(view.framesPerPoint)")
        let (inputs, updates, draws) = (view.lanes.inputs, view.updates, view.lanes.draws)

        lanes.report(0, 1)
        lanes.tick(1.05)

        let waveform = try lanes.waveform()
        let palette = view.lanes.palette
        let lane = try #require(view.lanes.surfaces.shown).laneRows
        let runs = try lanes.runs(at: 0.5, lane: 0)
        #expect(Self.near(runs, waveform), "\(runs)")
        #expect(try lanes.runs(at: 1.03, lane: 0) == [Run(palette.clip, lane)], "the box goes to the head")
        #expect(try lanes.runs(at: 0.5, lane: 1) == [Run(palette.lane, lane)], "the lane that is not armed")
        #expect(try lanes.runs(at: 2, lane: 0) == [Run(palette.lane, lane)], "after the head")
        #expect(view.lanes.inputs == inputs, "G1: the lane inputs stay the same")
        #expect(view.updates == updates)
        #expect(view.lanes.draws == draws + 1)
        await lanes.close()
    }

    // MARK: C16, G8

    /// 3 ticks per report at 60 Hz, each report 50 ms long and 100 ms behind the head.
    @Test func aLiveTickDrawsOnlyTheNewColumns() async throws {
        let lanes = try await take()
        let view = lanes.view
        var failures: [String] = []
        var head = 0.0
        for tick in 1...60 {
            let draws = view.lanes.draws
            let last = view.lanes.liveHead.map { Double($0.count) / Self.rate } ?? 0
            let now = Double(tick) / 60
            var low = last
            // A span before the take start writes nothing.
            if tick % 3 == 0, now > 0.15 {
                lanes.report(now - 0.15, now - 0.1)
                low = min(low, ((now - 0.15) / 0.05).rounded(.down) * 0.05)
            }
            lanes.tick(now)
            let points = { (seconds: Double) in seconds * Self.rate / view.framesPerPoint }
            let width = view.lanes.drawnRect.width
            let bound = points(now).rounded(.up) - points(low).rounded(.down) + 2
            if tick % 3 == 0, now > 0.15, view.lanes.draws != draws + 1 || width > bound {
                failures.append("tick \(tick): \(view.lanes.draws - draws) draws, width \(width) > \(bound)")
            }
            if tick % 3 != 0 || now <= 0.15, view.lanes.draws != draws {
                failures.append("tick \(tick): a tick with no bin drew")
            }
            head = now
        }
        #expect(failures.isEmpty, "\(failures.prefix(4))")
        #expect(head == 1)
        await lanes.close()
    }

    @Test func theSameTickTwiceDrawsOnce() async throws {
        let lanes = try await take()
        let draws = lanes.view.lanes.draws
        lanes.report(0, 0.5)

        lanes.tick(0.6)
        lanes.tick(0.6)

        #expect(lanes.view.lanes.draws == draws + 1)
        await lanes.close()
    }

    @Test func aTickWithNoNewBinDrawsNothing() async throws {
        let lanes = try await take()
        let view = lanes.view
        lanes.report(0, 0.5)
        lanes.tick(0.6)
        #expect(Self.near(try lanes.runs(at: 0.3, lane: 0), try lanes.waveform()), "a tick with a new bin draws")
        let draws = view.lanes.draws

        lanes.tick(1.6)

        #expect(
            abs(view.lanes.playhead.position.x - 1.6 * Self.rate / view.framesPerPoint) < 1e-6,
            "the tick moved the head line")
        #expect(view.lanes.draws == draws)
        await lanes.close()
    }

    /// F1: the head drew past a span that comes late. The next tick draws its waveform.
    @Test func aLateSpanDrawsItsWaveform() async throws {
        let lanes = try await take()
        lanes.report(0, 1)
        lanes.tick(1.5)
        let rows = try #require(lanes.view.lanes.surfaces.shown).laneRows
        #expect(try lanes.runs(at: 1.35, lane: 0) == [Run(lanes.view.lanes.palette.clip, rows)], "the box, no waveform")

        lanes.report(1.3, 1.4)
        lanes.tick(1.55)

        let runs = try lanes.runs(at: 1.35, lane: 0)
        #expect(Self.near(runs, try lanes.waveform()), "the late span: \(runs)")
        await lanes.close()
    }

    // MARK: C17, C17b

    @Test func aLostDeviceLeavesAGap() async throws {
        let lanes = try await take(armed: ["t1", "t2"])
        let (studio, palette) = (lanes.studio, lanes.view.lanes.palette)
        let rows = try #require(lanes.view.lanes.surfaces.shown).laneRows
        lanes.report(0, 1, track: "t1")
        lanes.report(0, 1, track: "t2")
        lanes.tick(1)
        studio.liveTracks["t2"]?.state = .deviceLost
        lanes.report(1, 2, track: "t1")
        lanes.tick(2.1)

        let waveform = try lanes.waveform()
        #expect(try lanes.runs(at: 1.5, lane: 1) == [Run(palette.lane, rows)], "the gap of the lost device")
        #expect(Self.near(try lanes.runs(at: 0.5, lane: 1), waveform))
        #expect(Self.near(try lanes.runs(at: 1.5, lane: 0), waveform))
        #expect(try lanes.runs(at: 2.05, lane: 0) == [Run(palette.clip, rows)], "the box goes to the head")

        lanes.stop(at: 2.5)
        lanes.tick(2.5)
        #expect(try lanes.runs(at: 2.05, lane: 0) == [Run(palette.lane, rows)], "the finalize: the covered frames only")
        #expect(Self.near(try lanes.runs(at: 1.5, lane: 0), waveform))
        await lanes.close()
    }

    /// Arm 2 fails at 1 s and opens again: its first span after the reopen starts at 2.5 s.
    @Test func aWriteFailureLeavesAGap() async throws {
        let lanes = try await take(armed: ["t1", "t2"])
        let (studio, palette) = (lanes.studio, lanes.view.lanes.palette)
        let rows = try #require(lanes.view.lanes.surfaces.shown).laneRows
        lanes.report(0, 1, track: "t1")
        lanes.report(0, 1, track: "t2")
        lanes.tick(1)
        studio.liveTracks["t2"]?.state = .writeFailed
        lanes.report(1, 2, track: "t1")
        lanes.tick(2)

        let waveform = try lanes.waveform()
        #expect(try lanes.runs(at: 1.5, lane: 1) == [Run(palette.lane, rows)], "no waveform after the failure")
        #expect(Self.near(try lanes.runs(at: 1.5, lane: 0), waveform), "the other arm of the device")

        studio.liveTracks["t2"]?.state = .recording
        lanes.report(2, 3, track: "t1")
        lanes.report(2.5, 3, track: "t2")
        lanes.tick(3)
        #expect(try lanes.runs(at: 1.75, lane: 1) == [Run(palette.lane, rows)], "the gap stays")
        #expect(try lanes.runs(at: 2.2, lane: 1) == [Run(palette.lane, rows)], "the drain of the reopen")
        #expect(Self.near(try lanes.runs(at: 2.75, lane: 1), waveform))
        await lanes.close()
    }

    // MARK: C19

    /// The label pixels: dark gray, not the blue of the RMS.
    func labelPixels(_ lanes: Lanes, from: Double, to: Double) throws -> [UInt32] {
        let window = try #require(lanes.view.lanes.surfaces.shown)
        let rows = window.rows(of: 0..<1)
        var pixels: [UInt32] = []
        for row in rows.upperBound - Int(16 * window.scale)..<rows.upperBound {
            for column in try lanes.column(from)..<lanes.column(to) {
                pixels.append(try #require(lanes.view.lanes.surfaces.pixel(column: column, row: row)))
            }
        }
        return pixels
    }

    @Test func theLiveRegionHasTheTakeLabel() async throws {
        let lanes = try await take()
        lanes.report(0, 1)
        lanes.tick(1)
        func gray(_ pixel: UInt32) -> Bool {
            let (r, g, b) = (Int(pixel >> 16 & 0xFF), Int(pixel >> 8 & 0xFF), Int(pixel & 0xFF))
            return r < 0x70 && abs(r - g) < 12 && abs(g - b) < 12
        }

        let recording = try labelPixels(lanes, from: 0, to: 1)
        #expect(recording.filter(gray).count > 10, "the label shows in the box")
        #expect(LiveLanes(lanes.studio, head: 48_000).take?.label == L10n.takeRecording.format(1))
        lanes.stop(at: 1)
        lanes.tick(1)
        #expect(LiveLanes(lanes.studio, head: 48_000).take?.label == L10n.takeFinishing.format(1))
        #expect(try labelPixels(lanes, from: 0, to: 1) != recording, "the finalize label shows")
        await lanes.close()
    }

    // MARK: C20

    @Test func liveColumnsAtTheClosestAndTheFitZoom() async throws {
        let lanes = try await take()
        let (model, view) = (lanes.model, lanes.view)
        // Bins of 50 ms with a loud bin at 0.6 s, after the take label.
        lanes.report(0, 0.6, peak: 0.1, rms: 0.05)
        lanes.report(0.6, 0.65, peak: 0.9, rms: 0.5)
        lanes.report(0.65, 0.9, peak: 0.1, rms: 0.05)
        model.timeline.scale = TimelineScale(framesPerPoint: 128)
        lanes.update()
        lanes.tick(0.9)
        let loud = try lanes.waveform(peak: 0.9, rms: 0.5)
        let quiet = try lanes.waveform(peak: 0.1, rms: 0.05)
        var columns: [String] = []
        for step in 1...9 {
            let seconds = 0.6 + Double(step) * 0.005
            let runs = try lanes.runs(at: seconds, lane: 0)
            if !Self.near(runs, loud) { columns.append("\(seconds): \(runs)") }
        }
        #expect(columns.isEmpty, "each column of the bin holds its value: \(columns), expected \(loud)")
        #expect(Self.near(try lanes.runs(at: 0.67, lane: 0), quiet))

        // Fit zoom of a 3 h history: one loud bin at 1 h.
        lanes.report(0.9, 10_800, peak: 0.1, rms: 0.05)
        lanes.report(3_600, 3_600.05, peak: 0.9, rms: 0.5)
        // The head at 98% of the view: Automatic Scroll would turn the page away from 1 h.
        model.timeline.follows = false
        model.timeline.scale = TimelineScale(framesPerPoint: 10_800 * Self.rate * 1.02 / Double(view.shown.width))
        lanes.update()
        lanes.tick(10_800)
        #expect(Self.near(try lanes.runs(at: 3_600.02, lane: 0), loud), "the column holds the largest bin")
        #expect(Self.near(try lanes.runs(at: 3_700, lane: 0), quiet))
        await lanes.close()
    }
}
