import Testing

@testable import DirigibleAudio

/// The watchdog rules of decision 0059 with the shipped limits (250 ms, 1 s, 2 s) and set
/// instants: no timer and no wall time.
struct HangRuleTests {
    let zero = ContinuousClock.now

    func at(_ ms: Int) -> ContinuousClock.Instant { zero + .milliseconds(ms) }

    func ticks(_ rule: inout HangRule, _ times: [Int]) -> [HangStep?] { times.map { rule.tick(now: at($0)) } }

    /// C9.
    @Test func aBlockPastTheLimitGivesOneStartAndOneEnd() {
        var rule = HangRule(limits: HangLimits())

        #expect(
            ticks(&rule, [0, 250, 500, 750, 1000]) == [.ping, nil, nil, nil, .hangStart(late: .milliseconds(1000))])
        #expect(rule.answered(now: at(1200)) == .hangEnd(blocked: .milliseconds(1200)))
        #expect(rule.tick(now: at(1250)) == .ping)
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
            ticks(&rule, [30_500, 30_750, 31_000, 31_250]) == [nil, nil, nil, .hangStart(late: .milliseconds(1000))])
    }

    /// C12: after a hang start, a late tick keeps the ping, so one hang has one start and one
    /// burst, also when the timer runs late under load.
    @Test func aLateTickInAStartedHangKeepsThePing() {
        var rule = HangRule(limits: HangLimits())

        #expect(ticks(&rule, [0, 250, 500, 750, 1000]).last == .hangStart(late: .milliseconds(1000)))
        #expect(ticks(&rule, [1600, 2000, 2700]) == [nil, .burst, nil])
        #expect(rule.answered(now: at(2800)) == .hangEnd(blocked: .milliseconds(2800)))
    }

    /// C12: under load the ticks come 600 ms apart during a 5 s block. The late limit counts from
    /// the first ping, so the block gets its start and its burst.
    @Test func lateTicksUnderLoadStillGiveAHangStart() {
        var rule = HangRule(limits: HangLimits())

        #expect(
            ticks(&rule, Array(stride(from: 0, through: 4800, by: 600))) == [
                .ping, nil, .hangStart(late: .milliseconds(1200)), nil, .burst, nil, nil, nil, nil,
            ])
    }

    /// C12 threshold: a tick 5 s after the last one is a normal tick, and a tick 5.001 s after it
    /// resets the ping.
    @Test func aTickUpTo5SecondsAfterTheLastIsNormal() {
        var normal = HangRule(limits: HangLimits())
        var reset = HangRule(limits: HangLimits())

        #expect(ticks(&normal, [0, 250, 5250]) == [.ping, nil, .hangStart(late: .milliseconds(5250))])
        #expect(ticks(&reset, [0, 250, 5251]) == [.ping, nil, .ping])
    }

    /// C13: four blocks of 2.5 s give four starts, and bursts only in the first three.
    @Test func atMostThreeBurstsInALaunch() {
        var rule = HangRule(limits: HangLimits())
        var startsAndBursts: [(starts: Int, bursts: Int)] = []

        for block in 0..<4 {
            let begin = block * 2500
            let steps = ticks(&rule, (0..<10).map { begin + $0 * 250 })
            #expect(rule.answered(now: at(begin + 2500)) == .hangEnd(blocked: .milliseconds(2500)))
            startsAndBursts.append(
                (steps.count { if case .hangStart = $0 { true } else { false } }, steps.count { $0 == .burst }))
        }

        #expect(startsAndBursts.map(\.starts) == [1, 1, 1, 1])
        #expect(startsAndBursts.map(\.bursts) == [1, 1, 1, 0])
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
