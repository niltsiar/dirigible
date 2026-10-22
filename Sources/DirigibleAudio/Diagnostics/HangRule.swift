/// The limits of the hang watchdog (decision 0059). Tests give short ones.
struct HangLimits: Sendable {
    /// The period of the timer that pings the watched queue.
    var interval = Duration.milliseconds(250)
    /// A tick more than this after the last tick comes after a sleep or a suspended process. A
    /// loaded Mac delays a tick by less, so a block under load still gets its start line. Tests
    /// set it past their run.
    var sleep = Duration.seconds(5)
    /// A ping with no answer for this long writes `hang start` and starts the burst of stacks.
    var late = Duration.seconds(1)
    /// The bursts in any `burstHour`.
    var bursts = 3
    var burstHour = Duration.seconds(3600)
    /// The stacks of one burst, and the pause before each stack after the first.
    var burstStacks = 10
    var burstPause = Duration.milliseconds(100)
}

/// What the watchdog does after a tick or an answer.
enum HangStep: Equatable {
    case ping
    /// `burst`: a burst of stacks follows the start line.
    case hangStart(late: Duration, burst: Bool)
    case hangEnd(blocked: Duration)
}

/// The late, sleep, and burst rules of the watchdog, with the instants as input, so a test needs
/// no timer and no wall time.
struct HangRule {
    let limits: HangLimits
    private var lastTick: ContinuousClock.Instant?
    /// The send time of the ping with no answer.
    private var sent: ContinuousClock.Instant?
    private var started = false
    /// The instants of the bursts in the last `burstHour`, oldest first.
    private var bursts: [ContinuousClock.Instant] = []
    private var stopped = false

    init(limits: HangLimits) { self.limits = limits }

    /// `.ping` with no ping out; `.hangStart` once when the ping is late, with a burst when fewer
    /// than `bursts` bursts came in the last `burstHour`. A tick more than `sleep` after the last
    /// tick comes after a sleep or a suspended process: before a hang start it sends a new ping and
    /// writes no line. After a hang start it keeps the ping, so one hang has one start and one burst.
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
        guard !started, waited >= limits.late else { return nil }
        started = true
        let hour = limits.burstHour
        bursts.removeAll { now - $0 >= hour }
        let burst = bursts.count < limits.bursts
        if burst { bursts.append(now) }
        return .hangStart(late: waited, burst: burst)
    }

    /// The answer of the ping: `.hangEnd` after a `.hangStart`, else nil.
    mutating func answered(now: ContinuousClock.Instant) -> HangStep? {
        guard !stopped, let sent else { return nil }
        defer {
            self.sent = nil
            started = false
        }
        return started ? .hangEnd(blocked: now - sent) : nil
    }

    mutating func stop() { stopped = true }
}
