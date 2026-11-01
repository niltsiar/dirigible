import DirigibleCore
import Foundation
import Testing

/// The window rules of the reads and the duck (decision 0062, criteria C1 and C4), on series of
/// 50 ms windows at 48 kHz (2400 frames) with no audio.
struct LevelSeriesTests {
    /// A series from `start` (a window index) with one window for each RMS level in dBFS.
    static func series(_ dB: [Double], start: Int = 0) throws -> LevelSeries {
        let levels = dB.map { WindowLevel(meanSquare: Float(pow(10, $0 / 10)), peak: Float(pow(10, $0 / 20))) }
        return try #require(
            LevelSeries(
                range: Frames(start * 2400)..<Frames((start + dB.count) * 2400), window: 2400, levels: levels))
    }

    /// `count` windows at `dB`.
    static func part(_ count: Int, _ dB: Double) -> [Double] { Array(repeating: dB, count: count) }

    static let threshold = Gain(dB: -40)!

    /// The frames of windows `first ..< end`.
    static func windows(_ first: Int, _ end: Int) -> Range<Frames> { Frames(first * 2400)..<Frames(end * 2400) }

    /// A 500 ms gap of one window at each level between loud windows.
    @Test func aWindowAtTheThresholdIsSilent() throws {
        for (dB, silent) in [(-41.0, true), (-40, true), (-39, false)] {
            let levels = try Self.series(Self.part(4, -20) + Self.part(10, dB) + Self.part(4, -20))
            let found = levels.silences(threshold: Self.threshold, minLength: 24_000, in: levels.range)
            #expect(found == (silent ? [Self.windows(4, 14)] : []), "\(dB) dBFS: \(found)")
        }
    }

    @Test func aGapUnderTheMinimumIsNoSilence() throws {
        let levels = try Self.series(
            Self.part(4, -20) + Self.part(10, -60) + Self.part(4, -20) + Self.part(9, -60) + Self.part(4, -20))
        let found = levels.silences(threshold: Self.threshold, minLength: 24_000, in: levels.range)
        #expect(found == [Self.windows(4, 14)], "\(found)")
    }

    /// Seeded random series: with a minimum of one frame, the silences and the runs over the
    /// threshold tile the whole range and alternate.
    @Test func silencesAreTheComplementOfTheRuns() throws {
        var state: UInt64 = 0x5EED_2026_1023
        func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        for _ in 0..<200 {
            let count = Int(next() % 60) + 1
            let dB = (0..<count).map { _ in next() % 3 == 0 ? -40 : -80 + Double(next() % 80) }
            let levels = try Self.series(dB, start: Int(next() % 5))
            let silences = levels.silences(threshold: Self.threshold, minLength: 1, in: levels.range)
            let runs = levels.runs(over: Self.threshold)
            let all = (silences + runs).sorted { $0.lowerBound < $1.lowerBound }
            let tiles = zip(all, all.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound }
            let alternate = zip(all, all.dropFirst()).allSatisfy { silences.contains($0) != silences.contains($1) }
            #expect(
                tiles && alternate && all.first?.lowerBound == levels.range.lowerBound
                    && all.last?.upperBound == levels.range.upperBound, "\(dB): \(silences) \(runs)")
        }
    }

    /// A 600 ms run with 100 ms inside the asked range is a silence with its whole extent; a 50 ms
    /// dip at the edge is not.
    @Test func theMinimumAppliesToTheUncutRun() throws {
        let levels = try Self.series(Self.part(2, -20) + Self.part(12, -60) + Self.part(10, -20) + Self.part(1, -60))
        let asked = Self.windows(12, 25)
        let found = levels.silences(threshold: Self.threshold, minLength: 24_000, in: asked)
        #expect(found == [Self.windows(2, 14)], "\(found)")
    }

    /// The scan and the step count check of `meter` take the window and the grid from here.
    @Test func theGridOfAReadIsWholeWindowsCutToTheEnd() {
        #expect(LevelSeries.window(rate: 48_000) == 2400 && LevelSeries.window(rate: 10) == 1)
        #expect(LevelSeries.grid(of: 1000..<5000, rate: 48_000, end: 100_000) == 0..<7200)
        #expect(LevelSeries.grid(of: 1000..<5000, rate: 48_000, end: 6000) == 0..<6000)
        #expect(LevelSeries.grid(of: 4800..<9600, rate: 48_000, end: 100_000) == 4800..<9600)
    }

    @Test func aSeriesWithTheWrongCountIsRefused() {
        let level = WindowLevel(meanSquare: 0, peak: 0)
        let tooMany = LevelSeries(range: 0..<4801, window: 2400, levels: Array(repeating: level, count: 4))
        let tooFew = LevelSeries(range: 0..<4801, window: 2400, levels: Array(repeating: level, count: 2))
        let right = LevelSeries(range: 0..<4801, window: 2400, levels: Array(repeating: level, count: 3))
        #expect(
            tooMany == nil && tooFew == nil && right != nil,
            "4: \(String(describing: tooMany)), 2: \(String(describing: tooFew))")
    }

    /// The default window is 2 s (96 000 frames) and the minimum 200 ms (9600 frames).
    @Test func theNearestPauseWins() throws {
        func pause(_ levels: LevelSeries, at: Int) -> Pause {
            levels.nearestPause(at: Frames(at), window: 96_000, threshold: Self.threshold, minLength: 9_600)
        }
        // `at` inside a 1 s silence that starts far before it, and a silence that starts 5400
        // frames after it: the silence that holds `at` wins.
        let inside = try Self.series(Self.part(20, -60) + Self.part(1, -20) + Self.part(10, -60) + Self.part(40, -20))
        #expect(pause(inside, at: 45_000) == .pause(Self.windows(0, 20), cut: 24_000), "inside")
        // `at` 12 000 frames from the end of one silence and from the start of the next.
        let tie = try Self.series(Self.part(10, -60) + Self.part(10, -20) + Self.part(10, -60) + Self.part(40, -20))
        #expect(pause(tie, at: 36_000) == .pause(Self.windows(0, 10), cut: 12_000), "tie")
        // A 200 ms gap is a pause, a 150 ms gap is not.
        let short = try Self.series(Self.part(40, -20) + Self.part(4, -60) + Self.part(40, -20))
        #expect(pause(short, at: 96_000) == .pause(Self.windows(40, 44), cut: 100_800), "200 ms")
        let shorter = try Self.series(Self.part(40, -20) + Self.part(3, -60) + Self.part(40, -20))
        guard case .noPause = pause(shorter, at: 96_000) else {
            Issue.record("150 ms: \(pause(shorter, at: 96_000))")
            return
        }
        // A silence across the edge of the asked range 0 ..< 168 000 is whole; its middle, 189 600,
        // is past that edge, so the cut is the last frame of the asked range.
        let edge = try Self.series(Self.part(69, -20) + Self.part(20, -60) + Self.part(11, -20))
        #expect(pause(edge, at: 72_000) == .pause(Self.windows(69, 89), cut: 167_999), "edge")
        // A silence that starts before the asked range 96 000 ..< 288 000: the cut is its first frame.
        let before = try Self.series(Self.part(10, -20) + Self.part(40, -60) + Self.part(80, -20))
        #expect(pause(before, at: 192_000) == .pause(Self.windows(10, 50), cut: 96_000), "before")
    }

    /// C31: the least threshold that gives a silence of 1 s (20 windows). One -50 dBFS window in a
    /// -38 dBFS floor is no silence alone, so the level is the floor. A run must meet the range.
    @Test func theQuietestRunIsTheLeastThresholdOfARow() throws {
        func dB(_ level: WindowLevel?) -> Double? { level.map { 10 * log10(Double($0.meanSquare)) } }
        let floor = try Self.series(Self.part(10, -38) + [-50] + Self.part(30, -38))
        let level = try #require(dB(floor.quietestRun(minLength: 48_000, in: floor.range)))
        #expect(abs(level + 38) < 0.1, "\(level) dBFS")
        let short = try Self.series(Self.part(19, -60))
        #expect(short.quietestRun(minLength: 48_000, in: short.range) == nil, "19 windows give a level")
        let whole = try Self.series(Self.part(20, -60))
        let sixty = try #require(dB(whole.quietestRun(minLength: 48_000, in: whole.range)))
        #expect(abs(sixty + 60) < 0.1, "\(sixty) dBFS")
        let outside = try Self.series(Self.part(20, -60) + Self.part(20, -30))
        let late = try #require(dB(outside.quietestRun(minLength: 48_000, in: Self.windows(30, 40))))
        #expect(abs(late + 30) < 0.1, "a run outside the range counts: \(late) dBFS")
    }

    /// With no silence, the cut is the middle of the quietest window, the earlier on a tie.
    @Test func withNoPauseTheQuietestWindowIsTheCut() throws {
        let levels = try Self.series(Self.part(10, -20) + [-30, -25, -30] + Self.part(10, -20))
        let found = levels.nearestPause(at: 30_000, window: 96_000, threshold: Self.threshold, minLength: 9_600)
        let expected = WindowLevel(meanSquare: Float(pow(10, -3.0)), peak: Float(pow(10, -1.5)))
        #expect(found == .noPause(cut: 25_200, level: expected), "\(found)")
    }
}
