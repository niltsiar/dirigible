import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Timeline-view criterion 9: 6 lanes of 2 h peaks into 2880 x 1200 px, at zoom to fit and at
/// the closest zoom, 120 draws each, with a p95 of 8 ms or less in an optimized build. `make test`
/// is unoptimized (a test run with -O runs the `dirigible` main), and this code measured a p95 of
/// 23 to 24 ms there, so the debug budget is 40 ms. A loop of one Swift step per pixel measured
/// 72 to 90 ms. For the optimized run, copy the package, make DirigibleApp a library target with no
/// `@main`, and run `swift test -c release -Xswiftc -enable-testing --filter LaneRenderBenchmark`
/// with the slow-test gate variable set to 1. (`make test-slow` counts each line that names it.)
struct LaneRenderBenchmark {
    #if DEBUG
        static let budget = Duration.milliseconds(40)
    #else
        static let budget = Duration.milliseconds(8)
    #endif

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func sixLanesOfTwoHoursDrawInTheBudget() throws {
        let frames = 345_600_000
        let peaks = randomPeaks(frames: frames)
        var session = Session(sampleRate: 48_000)
        var states: [FileID: PeakState] = [:]
        for n in 1...6 {
            let file = FileID("f\(n)")
            try session.addFile(AudioFile(id: file, path: "f\(n).wav", layout: .mono, length: Frames(frames)))
            try session.addTrack(TrackID("t\(n)"), name: "T\(n)", layout: .mono)
            try session.place(
                Clip(id: ClipID("c\(n)"), file: file, start: 0, offset: 0, length: Frames(frames)), on: TrackID("t\(n)")
            )
            states[file] = .ready(peaks)
        }
        // One muted track (mute and solo C11 f): the dim is a layer, so the lane draw stays the same.
        try session.setMuted(true, tracks: ["t2"])
        let renderer = LaneRenderer()

        for (zoom, framesPerPoint) in [("fit", Double(frames) / 1440), ("closest", 128.0)] {
            let inputs = LaneInputs(
                session: session, peaks: states, missingMedia: [:], selection: .none,
                scale: TimelineScale(framesPerPoint: framesPerPoint), laneHeight: 100)
            let windows = try (0..<7).map { try #require(laneWindow(inputs, x: Double($0), width: 1440, scale: 2)) }
            let pixels = windows.map { OwnedPixels($0) }
            var times: [Duration] = []
            for draw in 0..<120 {
                let start = ContinuousClock.now
                pixels[draw % 7].draw { renderer.draw(inputs, .light, into: $0) }
                times.append(ContinuousClock.now - start)
            }
            let p95 = times.sorted()[113]
            #expect(windows[0].pixels.columns.count == 2880 && windows[0].pixels.rows.count == 1200)
            expectWithinBudget(p95, Self.budget, "\(zoom): p95 \(p95)")
        }
    }
}

extension LaneRenderBenchmark {
    /// Gain envelope C12: 6 lanes of 2 h, each clip with 400 points that swing between 0 dB and
    /// -16 dB. At fit zoom the points are 3.6 pt apart, so the draw has the line and no disc; at the
    /// closest zoom they are 16 pt apart, so about 90 discs show on each lane. Each draw keeps the
    /// budget of a full draw.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aDenseEnvelopeDrawsInTheBudget() throws {
        let frames = 345_600_000
        let peaks = randomPeaks(frames: frames)
        for (zoom, framesPerPoint) in [("fit", Double(frames) / 1440), ("closest", 128.0)] {
            let spacing = zoom == "fit" ? frames / 400 : Int(16 * framesPerPoint)
            let points = (0..<400).map {
                GainEnvelope.Point(frame: Frames($0 * spacing), gain: Gain(dB: $0 % 2 == 0 ? 0 : -16)!)
            }
            let envelope = try #require(GainEnvelope(points))
            var session = Session(sampleRate: 48_000)
            var states: [FileID: PeakState] = [:]
            for n in 1...6 {
                let file = FileID("f\(n)")
                try session.addFile(AudioFile(id: file, path: "f\(n).wav", layout: .mono, length: Frames(frames)))
                try session.addTrack(TrackID("t\(n)"), name: "T\(n)", layout: .mono)
                try session.place(
                    Clip(
                        id: ClipID("c\(n)"), file: file, start: 0, offset: 0, length: Frames(frames),
                        envelope: envelope), on: TrackID("t\(n)"))
                states[file] = .ready(peaks)
            }
            let inputs = LaneInputs(
                session: session, peaks: states, missingMedia: [:], selection: .none,
                scale: TimelineScale(framesPerPoint: framesPerPoint), laneHeight: 100)
            let windows = try (0..<7).map { try #require(laneWindow(inputs, x: Double($0), width: 1440, scale: 2)) }
            let pixels = windows.map { OwnedPixels($0) }
            let renderer = LaneRenderer()
            var times: [Duration] = []
            for draw in 0..<120 {
                let start = ContinuousClock.now
                pixels[draw % 7].draw { renderer.draw(inputs, .light, into: $0) }
                times.append(ContinuousClock.now - start)
            }
            let p95 = times.sorted()[113]
            print("LaneRenderBenchmark dense envelope, \(zoom): p50 \(times.sorted()[60]), p95 \(p95)")
            expectWithinBudget(p95, Self.budget, "\(zoom): p95 \(p95)")
        }
    }
}

extension LaneRenderBenchmark {
    /// Timeline clarity C11: 6 lanes of clips of 12 pt that all touch, so the view holds 120 joins
    /// on each lane, drawn at scale 2 over ready peaks. The draw keeps the budget of a full draw.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func buttJoinsAtTwelvePointsDrawInTheBudget() throws {
        let framesPerPoint = 512.0
        let clip = Int(12 * framesPerPoint)
        let frames = clip * 400
        let peaks = randomPeaks(frames: frames)
        var session = Session(sampleRate: 48_000)
        var states: [FileID: PeakState] = [:]
        for n in 1...6 {
            let file = FileID("f\(n)")
            try session.addFile(AudioFile(id: file, path: "f\(n).wav", layout: .mono, length: Frames(frames)))
            try session.addTrack(TrackID("t\(n)"), name: "T\(n)", layout: .mono)
            for index in 0..<400 {
                try session.place(
                    Clip(
                        id: ClipID("c\(n)x\(index)"), file: file, start: Frames(index * clip),
                        offset: Frames(index * clip), length: Frames(clip)), on: TrackID("t\(n)"))
            }
            states[file] = .ready(peaks)
        }
        let inputs = LaneInputs(
            session: session, peaks: states, missingMedia: [:], selection: .none,
            scale: TimelineScale(framesPerPoint: framesPerPoint), laneHeight: 100)
        let windows = try (0..<7).map { try #require(laneWindow(inputs, x: Double($0), width: 1440, scale: 2)) }
        let pixels = windows.map { OwnedPixels($0) }
        let renderer = LaneRenderer()
        var times: [Duration] = []
        for draw in 0..<120 {
            let start = ContinuousClock.now
            pixels[draw % 7].draw { renderer.draw(inputs, .light, into: $0) }
            times.append(ContinuousClock.now - start)
        }
        let p95 = times.sorted()[113]
        expectWithinBudget(p95, Self.budget, "p95 \(p95)")
    }
}

/// Run 2026-10-11-ui-polish-header C17 (premortem 4): an edited episode, 6 lanes of clips of 60 to
/// 200 pt with gains that are not 0, about 17 labeled clips per lane in view. The full draw of the
/// view (the labels once, the lane pixels with their chips, the label texts) at 2880 x 1200 px
/// takes 16 ms p95 or less in an optimized build (the 0020 budget of a full draw).
@MainActor struct ManyLabelsBenchmark {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func manyLabels() throws {
        let framesPerPoint = 512.0
        let peaks = randomPeaks(frames: 345_600_000)
        var session = Session(sampleRate: 48_000)
        var states: [FileID: PeakState] = [:]
        for n in 1...6 {
            let file = FileID("f\(n)")
            try session.addFile(AudioFile(id: file, path: "take\(n).wav", layout: .mono, length: 345_600_000))
            try session.addTrack(TrackID("t\(n)"), name: "T\(n)", layout: .mono)
            states[file] = .ready(peaks)
            var start = 0
            for index in 0..<200 {
                let points = [60, 60, 60, 70, 200][index % 5]
                let length = Int(Double(points) * framesPerPoint)
                let gain = try #require(Gain(dB: -3.5))
                try session.place(
                    Clip(
                        id: ClipID("c\(n)x\(index)"), file: file, start: Frames(start), offset: Frames(start),
                        length: Frames(length), gain: gain), on: TrackID("t\(n)"))
                start += length
            }
        }
        let inputs = LaneInputs(
            session: session, peaks: states, missingMedia: [:], selection: .none,
            scale: TimelineScale(framesPerPoint: framesPerPoint), laneHeight: 100)
        let windows = try (0..<7).map { try #require(laneWindow(inputs, x: Double($0), width: 1440, scale: 2)) }
        let pixels = windows.map { OwnedPixels($0) }
        let renderer = LaneRenderer()
        var labels = 0
        pixels[0].draw { labels = ClipLabel.labels(inputs, live: nil, in: $0).count }
        #expect(labels >= 6 * 16, "labeled clips in view: \(labels)")
        var times: [Duration] = []
        for draw in 0..<120 {
            let start = ContinuousClock.now
            pixels[draw % 7].draw { TimelineDocumentView.drawLanes(renderer, inputs, .light, into: $0) }
            times.append(ContinuousClock.now - start)
        }
        let p95 = times.sorted()[113]
        expectWithinBudget(p95, .milliseconds(16), "p95 \(p95)")
    }
}

/// Code gate 1 item 3: a draw of 10 pt of 6 lanes of 1000 clips each labels only the clips in the
/// dirty rect. Unoptimized, on the MacBook Pro 2018 of the probes: a median of 10.5 s when the
/// labels looked up every clip of the session by its ID, 8.5 ms after the fix. The labels draw
/// into the region of the draw (decision 0022).
@MainActor struct ClipLabelBenchmark {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aNarrowDrawOfManyClipsReadsOnlyItsClips() throws {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f1", path: "f1.wav", layout: .mono, length: 4800))
        for track in 1...6 {
            try session.addTrack(TrackID("t\(track)"), name: "T\(track)", layout: .mono)
            for n in 0..<1000 {
                try session.place(
                    Clip(id: ClipID("c\(track)x\(n)"), file: "f1", start: Frames(n * 4800), offset: 0, length: 4800),
                    on: TrackID("t\(track)"))
            }
        }
        let inputs = LaneInputs(
            session: session, peaks: [:], missingMedia: [:], selection: .none,
            scale: TimelineScale(framesPerPoint: 512),
            laneHeight: 100)
        let pixels = OwnedPixels(try #require(laneWindow(inputs, x: 4000, width: 10, scale: 2)))

        var times: [Duration] = []
        for _ in 0..<20 {
            let start = ContinuousClock.now
            pixels.draw { region in
                TimelineDocumentView.drawLabels(ClipLabel.labels(inputs, live: nil, in: region), .light, into: region)
            }
            times.append(ContinuousClock.now - start)
        }
        let median = times.sorted()[10]
        expectWithinBudget(median, .milliseconds(20), "median \(median)")
    }
}

extension LaneRenderBenchmark {
    /// Leveler C30 and U40: 6 lanes of 2 h, each clip with a ride of 18,954 points (the points of a
    /// decimated ride of 2 h) and a duck of 4 envelope points, so each column sums two layers. At
    /// fit zoom and at the closest zoom, each draw keeps the budget of a full draw.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aRiddenClipDrawsInTheBudget() throws {
        let frames = 345_600_000
        let peaks = randomPeaks(frames: frames)
        var random = SplitMix(seed: 40)
        let spacing = frames / 18_954
        let ride = try #require(
            GainEnvelope(
                (0..<18_954).map {
                    GainEnvelope.Point(
                        frame: Frames($0 * spacing), gain: Gain(dB: .random(in: -6...6, using: &random))!)
                }))
        let duck = try #require(
            GainEnvelope(
                [(0, 0.0), (frames / 4, -16), (frames / 2, -16), (3 * frames / 4, 0)].map {
                    GainEnvelope.Point(frame: Frames($0.0), gain: Gain(dB: $0.1)!)
                }))
        var session = Session(sampleRate: 48_000)
        var states: [FileID: PeakState] = [:]
        var rides: [ClipID: GainEnvelope] = [:]
        for n in 1...6 {
            let file = FileID("f\(n)")
            try session.addFile(AudioFile(id: file, path: "f\(n).wav", layout: .mono, length: Frames(frames)))
            try session.addTrack(TrackID("t\(n)"), name: "T\(n)", layout: .mono)
            try session.place(
                Clip(id: ClipID("c\(n)"), file: file, start: 0, offset: 0, length: Frames(frames), envelope: duck),
                on: TrackID("t\(n)"))
            rides[ClipID("c\(n)")] = ride
            states[file] = .ready(peaks)
        }
        try session.setRides(rides)
        let renderer = LaneRenderer()
        for (zoom, framesPerPoint) in [("fit", Double(frames) / 1440), ("closest", 128.0)] {
            let inputs = LaneInputs(
                session: session, peaks: states, missingMedia: [:], selection: .none,
                scale: TimelineScale(framesPerPoint: framesPerPoint), laneHeight: 100)
            let windows = try (0..<7).map { try #require(laneWindow(inputs, x: Double($0), width: 1440, scale: 2)) }
            let pixels = windows.map { OwnedPixels($0) }
            var times: [Duration] = []
            for draw in 0..<120 {
                let start = ContinuousClock.now
                pixels[draw % 7].draw { renderer.draw(inputs, .light, into: $0) }
                times.append(ContinuousClock.now - start)
            }
            let p95 = times.sorted()[113]
            print("LaneRenderBenchmark ridden clips, \(zoom): p50 \(times.sorted()[60]), p95 \(p95)")
            expectWithinBudget(p95, Self.budget, "\(zoom): p95 \(p95)")
        }
    }
}

/// SplitMix64, so the benchmark draws the same peaks on each run.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
