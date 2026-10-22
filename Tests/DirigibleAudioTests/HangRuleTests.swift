import Testing

@testable import DirigibleAudio

/// The watchdog rules of decision 0059 with the shipped limits (250 ms ticks, 1 s late, 5 s reset,
/// 3 bursts in any hour) and set instants: no timer and no wall time.
struct HangRuleTests {
    let zero = ContinuousClock.now

    func at(_ ms: Int) -> ContinuousClock.Instant { zero + .milliseconds(ms) }

    func ticks(_ rule: inout HangRule, _ times: [Int]) -> [HangStep?] { times.map { rule.tick(now: at($0)) } }

    /// A hang with its start tick at `start`: ticks each 250 ms from the ping 1 s before, and an
    /// answer 200 ms after the start. Gives the step of the start tick.
    func hang(_ rule: inout HangRule, startingAt start: Int) -> HangStep? {
        let steps = ticks(&rule, Array(stride(from: start - 1000, through: start, by: 250)))
        _ = rule.answered(now: at(start + 200))
        return steps.last ?? nil
    }

    /// C9.
    @Test func aBlockPastTheLimitGivesOneStartAndOneEnd() {
        var rule = HangRule(limits: HangLimits())

        #expect(
            ticks(&rule, [0, 250, 500, 750, 1000]) == [
                .ping, nil, nil, nil, .hangStart(late: .milliseconds(1000), burst: true),
            ])
        #expect(rule.answered(now: at(1200)) == .hangEnd(blocked: .milliseconds(1200)))
        #expect(rule.tick(now: at(1250)) == .ping)
    }

    /// watchdog-hangs C2: a hang of 1.5 s gets one start with a burst and one end.
    @Test func aHangOf1Point5SecondsGetsABurst() {
        var rule = HangRule(limits: HangLimits())

        let steps = ticks(&rule, Array(stride(from: 0, through: 1250, by: 250)))

        #expect(steps == [.ping, nil, nil, nil, .hangStart(late: .milliseconds(1000), burst: true), nil])
        #expect(rule.answered(now: at(1500)) == .hangEnd(blocked: .milliseconds(1500)))
    }

    /// watchdog-hangs C1: a ping 1000 ms late gives the start with a burst. A ping 999 ms late
    /// gives no step, and its answer gives none.
    @Test func aPing1SecondLateGivesTheStartAndTheBurst() {
        var late = HangRule(limits: HangLimits())
        var early = HangRule(limits: HangLimits())

        #expect(
            ticks(&late, [0, 250, 500, 750, 1000]) == [
                .ping, nil, nil, nil, .hangStart(late: .milliseconds(1000), burst: true),
            ])
        #expect(ticks(&early, [0, 250, 500, 750, 999]) == [.ping, nil, nil, nil, nil])
        #expect(early.answered(now: at(999)) == nil)
    }

    /// C9: an answer before the late limit ends the ping with no line, and the next tick pings again.
    @Test func aShortBlockGivesNoStep() {
        var rule = HangRule(limits: HangLimits())

        #expect(ticks(&rule, [0, 250, 500, 750]) == [.ping, nil, nil, nil])
        #expect(rule.answered(now: at(800)) == nil)
        #expect(rule.tick(now: at(1000)) == .ping)
    }

    /// C12: a tick 30 s after the last one (a sleep) pings again with no line, and the late limit
    /// counts from the new ping.
    @Test func aSleepResetsThePing() {
        var rule = HangRule(limits: HangLimits())

        #expect(ticks(&rule, [0, 250, 30_250]) == [.ping, nil, .ping])
        #expect(
            ticks(&rule, [30_500, 30_750, 31_000, 31_250]) == [
                nil, nil, nil, .hangStart(late: .milliseconds(1000), burst: true),
            ])
    }

    /// C12, watchdog-hangs C3: after a hang start with its burst, a late tick keeps the ping and
    /// gives no step, so one hang has one start and one burst, also when the timer runs late under
    /// load.
    @Test func aLateTickInAStartedHangKeepsThePing() {
        var rule = HangRule(limits: HangLimits())

        #expect(ticks(&rule, [0, 250, 500, 750, 1000]).last == .hangStart(late: .milliseconds(1000), burst: true))
        #expect(ticks(&rule, [1600, 2000, 2700]) == [nil, nil, nil])
        #expect(rule.answered(now: at(2800)) == .hangEnd(blocked: .milliseconds(2800)))
    }

    /// C12: under load the ticks come 600 ms apart during a 5 s block. The late limit counts from
    /// the first ping, so the block gets its start with its burst.
    @Test func lateTicksUnderLoadStillGiveAHangStart() {
        var rule = HangRule(limits: HangLimits())

        #expect(
            ticks(&rule, Array(stride(from: 0, through: 4800, by: 600))) == [
                .ping, nil, .hangStart(late: .milliseconds(1200), burst: true), nil, nil, nil, nil, nil, nil,
            ])
    }

    /// C12 threshold: a tick 5 s after the last one is a normal tick, and a tick 5.001 s after it
    /// resets the ping.
    @Test func aTickUpTo5SecondsAfterTheLastIsNormal() {
        var normal = HangRule(limits: HangLimits())
        var reset = HangRule(limits: HangLimits())

        #expect(ticks(&normal, [0, 250, 5250]) == [.ping, nil, .hangStart(late: .milliseconds(5250), burst: true)])
        #expect(ticks(&reset, [0, 250, 5251]) == [.ping, nil, .ping])
    }

    /// watchdog-hangs C4: hangs that start at 0, 10, 20, and 30 min get a burst in the first
    /// three only. A hang 3600 s after the first burst gets a burst; 1 ms earlier it gets only its
    /// start.
    @Test func atMostThreeBurstsInAnHour() {
        let minute = 60_000
        func start(burst: Bool) -> HangStep { .hangStart(late: .milliseconds(1000), burst: burst) }
        var rule = HangRule(limits: HangLimits())
        var onTheHour = HangRule(limits: HangLimits())
        var beforeTheHour = HangRule(limits: HangLimits())

        let starts = [0, 10, 20, 30].map { hang(&rule, startingAt: $0 * minute) }
        for begin in [0, 10, 20] {
            _ = hang(&onTheHour, startingAt: begin * minute)
            _ = hang(&beforeTheHour, startingAt: begin * minute)
        }

        #expect(starts == [start(burst: true), start(burst: true), start(burst: true), start(burst: false)])
        #expect(hang(&onTheHour, startingAt: 3_600_000) == start(burst: true))
        #expect(hang(&beforeTheHour, startingAt: 3_599_999) == start(burst: false))
    }

    /// C43: after `stop()`, no tick and no answer gives a step.
    @Test func aStoppedRuleGivesNoStep() {
        var rule = HangRule(limits: HangLimits())
        #expect(rule.tick(now: at(0)) == .ping)

        rule.stop()

        #expect(ticks(&rule, Array(stride(from: 250, through: 2500, by: 250))).allSatisfy { $0 == nil })
        #expect(rule.answered(now: at(2600)) == nil)
        #expect(rule.tick(now: at(2750)) == nil)
    }
}
