/// The limits of the hang watchdog (decision 0059). Tests give short ones.
struct HangLimits: Sendable {
    /// The period of the timer that pings the watched queue.
    var interval = Duration.milliseconds(250)
    /// A tick more than this after the last tick (the deadline plus one interval) comes after a
    /// sleep or a suspended process. Tests set it past their run, so a loaded test timer is no sleep.
    var sleep = Duration.milliseconds(500)
    /// A ping with no answer for this long writes `hang start`.
    var late = Duration.seconds(1)
    /// A ping with no answer for this long starts the burst of stacks.
    var stacks = Duration.seconds(2)
    /// The bursts of one launch.
    var bursts = 3
    /// The stacks of one burst, and the pause before each stack after the first.
    var burstStacks = 10
    var burstPause = Duration.milliseconds(100)
}

/// What the watchdog does after a tick or an answer.
enum HangStep: Equatable {
    case ping
    case hangStart(late: Duration)
    case hangEnd(blocked: Duration)
    case burst
}

/// The late, sleep, and burst rules of the watchdog, with the instants as input, so a test needs
/// no timer and no wall time.
struct HangRule {
    let limits: HangLimits
    private var lastTick: ContinuousClock.Instant?
    /// The send time of the ping with no answer.
    private var sent: ContinuousClock.Instant?
    private var started = false
    private var burstDone = false
    private var bursts = 0
    private var stopped = false

    init(limits: HangLimits) { self.limits = limits }

    /// `.ping` with no ping out; `.hangStart` once when the ping is late; `.burst` once when the
    /// ping waits past the stack limit. A tick later than `sleep` after the last tick comes after
    /// a sleep or a suspended process: before a hang start it sends a new ping and writes no
    /// line. After a hang start it keeps the ping, so one hang has one start and one burst.
    mutating func tick(now: ContinuousClock.Instant) -> HangStep? {
        guard !stopped else { return nil }
        defer { lastTick = now }
        if !started, let lastTick, now - lastTick > limits.sleep {
            sent = now
            return .ping
        }
        guard let sent else {
            self.sent = now
            return .ping
        }
        let waited = now - sent
        if !started {
            guard waited >= limits.late else { return nil }
            started = true
            return .hangStart(late: waited)
        }
        guard !burstDone, bursts < limits.bursts, waited >= limits.stacks else { return nil }
        burstDone = true
        bursts += 1
        return .burst
    }

    /// The answer of the ping: `.hangEnd` after a `.hangStart`, else nil.
    mutating func answered(now: ContinuousClock.Instant) -> HangStep? {
        guard !stopped, let sent else { return nil }
        defer {
            self.sent = nil
            started = false
            burstDone = false
        }
        return started ? .hangEnd(blocked: now - sent) : nil
    }

    mutating func stop() { stopped = true }
}
