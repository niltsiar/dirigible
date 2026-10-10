import Foundation
import Testing

@testable import DirigibleAudio

/// The input and output sizes of one A3 case. The pull is the output block at the input rate:
/// 512 frames out at 44.1 kHz pull 557 or 558 frames at 48 kHz.
struct ListenSizes: Sendable, CustomTestStringConvertible {
    let inputBlock: Int
    let inputRate: Double
    let outputBlock: Int
    let outputRate: Double

    var testDescription: String { "(\(inputBlock) at \(Int(inputRate)), \(outputBlock) at \(Int(outputRate)))" }
    var pullMean: Double { Double(outputBlock) * inputRate / outputRate }

    static let sweep = [
        ListenSizes(inputBlock: 512, inputRate: 48_000, outputBlock: 512, outputRate: 48_000),
        ListenSizes(inputBlock: 512, inputRate: 48_000, outputBlock: 128, outputRate: 48_000),
        ListenSizes(inputBlock: 512, inputRate: 48_000, outputBlock: 1024, outputRate: 48_000),
        ListenSizes(inputBlock: 4096, inputRate: 16_000, outputBlock: 512, outputRate: 48_000),
        ListenSizes(inputBlock: 512, inputRate: 48_000, outputBlock: 512, outputRate: 44_100),
    ]
}

/// The result of a simulated run of the rule on an integer fill.
struct DriftRun {
    var underruns = 0
    var overruns = 0
    var skips = 0
    var corrections = 0
    var correctionsAfterFirstMinute = 0
    var played = 0
    var lowestError = Int.max
    var highestError = Int.min
    var rule: DriftRule
}

/// Runs the rule against two simulated clocks for `seconds` (the model of the gate 2 simulation,
/// `sim/drift_sim.py` of run 2026-10-10-record-monitor). The input pushes one block each period
/// of its clock, which is `ppm` fast; the output pulls one block at its own rate, 0.37 periods
/// after the first push. Each time is a product, not a sum, so 2 h adds no rounding error. The
/// window error of the first window is not in the range: the prime sets it.
func simulate(_ sizes: ListenSizes, ppm: Double, seconds: Double) -> DriftRun {
    let mean = sizes.pullMean
    var run = DriftRun(
        rule: DriftRule(inputBlock: sizes.inputBlock, pull: Int(mean.rounded(.up)), rate: sizes.inputRate))
    let pushPeriod = Double(sizes.inputBlock) / (sizes.inputRate * (1 + ppm * 1e-6))
    let pullPeriod = Double(sizes.outputBlock) / sizes.outputRate
    var fill = 0
    var pushes = 0
    var pulls = 0
    var pushTime = 0.0
    var pullTime = 0.37 * pullPeriod
    while true {
        if pushTime <= pullTime {
            guard pushTime <= seconds else { break }
            if fill + sizes.inputBlock > ListenRing.capacity { run.overruns += 1 } else { fill += sizes.inputBlock }
            pushes += 1
            pushTime = Double(pushes) * pushPeriod
            continue
        }
        guard pullTime <= seconds else { break }
        pulls += 1
        let want = Int((Double(pulls) * mean).rounded(.down)) - Int((Double(pulls - 1) * mean).rounded(.down))
        let now = pullTime
        pullTime = (Double(pulls) + 0.37) * pullPeriod
        let windows = run.rule.counts.windows
        if case .play(let skip, let read) = run.rule.pull(frames: want, available: fill, pushed: sizes.inputBlock) {
            fill -= skip + read
            run.played += want
            if read != want {
                run.corrections += 1
                if now > 60 { run.correctionsAfterFirstMinute += 1 }
            }
        }
        if run.rule.counts.windows > windows, run.rule.counts.windows >= 2, let error = run.rule.lastError {
            run.lowestError = min(run.lowestError, error)
            run.highestError = max(run.highestError, error)
        }
    }
    run.underruns = run.rule.counts.underruns
    run.skips = run.rule.counts.skips
    return run
}

/// The A3 checks of one run: no underrun, overrun, or skip; the window minimum within one block
/// plus the band of the target; and the correction budget of plan gate 2.
func expectA3(_ run: DriftRun, _ sizes: ListenSizes, ppm: Double, seconds: Double) {
    let block = max(sizes.inputBlock, Int(sizes.pullMean.rounded(.up)))
    let band = Int((sizes.inputRate / 1000).rounded())
    #expect(run.underruns == 0, "A3 underruns")
    #expect(run.overruns == 0, "A3 overruns")
    #expect(run.skips == 0, "A3 skips")
    #expect(run.played >= Int(0.99 * seconds * sizes.inputRate), "A3 plays")
    #expect(run.lowestError >= -block - band && run.highestError <= block + band, "A3 window minimum")
    if ppm == 0 {
        #expect(run.corrections <= block, "A3 budget at 0 ppm")
        #expect(run.correctionsAfterFirstMinute == 0, "A3 settles in the first minute")
    } else {
        let need = Int((abs(ppm) * 1e-6 * sizes.inputRate * seconds).rounded())
        #expect(run.corrections <= need + 2 * block, "A3 budget")
    }
}

/// A3: the drift rule over 2 h for each pair of sizes (analysis.md A3, plan slice 3).
struct DriftRuleTests {
    static let twoHours = 7200.0

    @Test(arguments: ListenSizes.sweep)
    func aFastInputClockDoesNotOverrun(_ sizes: ListenSizes) {
        expectA3(simulate(sizes, ppm: 250, seconds: Self.twoHours), sizes, ppm: 250, seconds: Self.twoHours)
    }

    @Test(arguments: ListenSizes.sweep)
    func aSlowInputClockDoesNotUnderrun(_ sizes: ListenSizes) {
        expectA3(simulate(sizes, ppm: -250, seconds: Self.twoHours), sizes, ppm: -250, seconds: Self.twoHours)
    }

    @Test(arguments: ListenSizes.sweep)
    func aSharedClockSettlesInTheFirstMinute(_ sizes: ListenSizes) {
        expectA3(simulate(sizes, ppm: 0, seconds: Self.twoHours), sizes, ppm: 0, seconds: Self.twoHours)
    }

    /// One clock domain with the push and the pull of each cycle in a seeded random order (probe
    /// P2: the fill after a pop is 0 or 512 frames over the minimum). The prime can land on the
    /// high phase, so the rule can correct one block once; after the first minute it makes none.
    @Test func oneClockDomainMakesNoCorrection() {
        var ring = RuleDriver(DriftRule(inputBlock: 512, pull: 512, rate: 48_000))
        var random = SeededGenerator(seed: 7)
        for cycle in 0..<56_250 {  // 10 min
            if Bool.random(using: &random) {
                ring.push(512)
                ring.pull(512, at: cycle)
            } else {
                ring.pull(512, at: cycle)
                ring.push(512)
            }
        }
        #expect(ring.rule.counts.underruns == 0 && ring.rule.counts.skips == 0, "P2 order: no underrun or skip")
        #expect(ring.corrections <= 512, "P2 order: at most one block of corrections")
        #expect(ring.correctionsAfter(cycle: 5625) == 0, "P2 order: no correction after the first minute")
        #expect(ring.played > 56_000 * 512, "P2 order: the ring plays")
    }

    /// A fast input clock brings two pushes in one pull interval: the minimum rises by one block,
    /// and the rule drops frames, with no skip.
    @Test func aPhaseCrossingDoesNotSkip() {
        var ring = RuleDriver(DriftRule(inputBlock: 512, pull: 512, rate: 48_000))
        ring.cycles(282)  // 3 s
        ring.push(512)
        let crossing = ring.cycle
        ring.cycles(940)  // 10 s
        let errors = ring.errors.filter { $0.cycle > crossing }.map(\.error)
        #expect(errors.contains { abs($0 - 512) <= 48 }, "phase crossing: the minimum rises by one block")
        #expect(ring.rule.counts.skips == 0, "phase crossing: no skip")
        #expect(ring.rule.counts.drops >= 512 - 48 && ring.rule.counts.drops <= 512, "phase crossing: drops one block")
        #expect(ring.rule.counts.underruns == 0, "phase crossing: no underrun")
    }

    /// A render gap of 0.5 s (probe P3b: a default output change) leaves 24064 frames more in the
    /// ring. The end of the first full window after the gap skips to the target, within 2 s.
    @Test func aRenderGapSkipsToTheTarget() {
        var ring = RuleDriver(DriftRule(inputBlock: 512, pull: 512, rate: 48_000))
        ring.cycles(300)
        for _ in 0..<47 { ring.push(512) }
        ring.cycles(188)  // 2 s
        let target = ring.rule.target
        #expect(ring.rule.counts.skips == 1, "render gap: one skip")
        #expect(abs(ring.fill - target) <= ring.rule.band, "render gap: back at the target within 2 s")
        #expect(ring.rule.counts.underruns == 0, "render gap: no underrun")
    }

    /// An excess over the band and under the skip threshold leaves the ring one frame per render,
    /// until the error of a window end is inside the band.
    @Test func aSmallExcessCorrectsFrameByFrame() {
        var ring = RuleDriver(DriftRule(inputBlock: 512, pull: 512, rate: 48_000))
        ring.cycles(300)
        ring.push(100)
        ring.cycles(400)
        #expect(
            ring.rule.counts.drops >= 100 - 48 && ring.rule.counts.drops <= 100, "small excess: drops into the band")
        #expect(ring.rule.counts.repeats == 0 && ring.rule.counts.skips == 0, "small excess: no repeat or skip")
        #expect(ring.reads.allSatisfy { abs($0) <= 1 }, "small excess: one frame per render")
    }

    /// A pull of 1024 after 512 (a default output with a larger buffer) makes a new rule with a
    /// larger target, which primes again and then plays with no underrun.
    @Test func aLargerPullRaisesTheTarget() {
        var ring = RuleDriver(DriftRule(inputBlock: 512, pull: 512, rate: 48_000))
        ring.cycles(200)
        #expect(ring.rule.target == 608)
        for cycle in 0..<940 {
            ring.push(512)
            ring.push(512)
            ring.pull(1024, at: 200 + cycle)
        }
        #expect(ring.rule.target == 1024 + 96, "larger pull: a new target")
        #expect(ring.rule.counts.underruns == 0, "larger pull: no underrun")
        #expect(ring.played > 900 * 1024, "larger pull: the ring plays")
    }
}

/// An integer fill and a rule, driven one push or pull at a time.
struct RuleDriver {
    var rule: DriftRule
    var fill = 0
    var cycle = 0
    var played = 0
    var reads: [Int] = []
    var corrected: [Int] = []
    var errors: [(cycle: Int, error: Int)] = []

    init(_ rule: DriftRule) { self.rule = rule }

    var corrections: Int { corrected.count }
    func correctionsAfter(cycle: Int) -> Int { corrected.filter { $0 >= cycle }.count }

    mutating func push(_ frames: Int) { fill += frames }

    mutating func pull(_ frames: Int, at cycle: Int) {
        let windows = rule.counts.windows
        if case .play(let skip, let read) = rule.pull(frames: frames, available: fill, pushed: 512) {
            fill -= skip + read
            played += frames
            reads.append(read - frames)
            if read != frames { corrected.append(cycle) }
        }
        if rule.counts.windows > windows, let error = rule.lastError { errors.append((cycle, error)) }
    }

    /// `count` cycles of one push, then one pull, of 512 frames.
    mutating func cycles(_ count: Int) {
        for _ in 0..<count {
            push(512)
            pull(512, at: cycle)
            cycle += 1
        }
    }
}
