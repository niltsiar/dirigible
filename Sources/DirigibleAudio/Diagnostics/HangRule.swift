/// The limits of the hang watchdog (decision 0059). Tests give short ones.
struct HangLimits: Sendable {
    /// The period of the timer that pings the watched queue.
    var interval = Duration.milliseconds(250)
    /// A tick more than this awake time after the last tick comes after a suspended process, a
    /// stalled watchdog, or a timer that App Nap holds. A loaded Mac delays a tick by less, so a
    /// block under load still gets its start line. Tests set it past their run.
    var sleep = Duration.seconds(5)
    /// A ping with no answer for this awake time writes `hang start` and starts the burst of stacks.
    var late = Duration.seconds(1)
    /// The bursts in any `burstHour` of continuous time, so the hour counts sleep.
    var bursts = 3
    var burstHour = Duration.seconds(3600)
    /// The stacks of one burst, and the pause before each stack after the first.
    var burstStacks = 10
    var burstPause = Duration.milliseconds(100)
}

/// One reading of both clocks. The rules count awake time; the burst hour and `slept` count sleep
/// too.
struct HangInstant: Equatable, Sendable {
    var awake: SuspendingClock.Instant
    var continuous: ContinuousClock.Instant

    static var now: HangInstant { HangInstant(awake: .now, continuous: .now) }
}

/// What the watchdog does after a tick or an answer.
enum HangStep: Equatable {
    case ping
    /// `burst`: a burst of stacks follows the start line.
    case hangStart(late: Duration, tickGap: Duration, burst: Bool)
    case hangEnd(blocked: Duration, slept: Duration, tickGap: Duration)
}

/// The late, sleep, and burst rules of the watchdog, with the instants as input, so a test needs
/// no timer and no wall time.
struct HangRule {
    let limits: HangLimits
    private var lastTick: HangInstant?
    /// The send time of the ping with no answer.
    private var sent: HangInstant?
    private var started = false
    /// The longest awake gap between two ticks since the ping.
    private var tickGap = Duration.zero
    /// The instants of the bursts in the last `burstHour`, oldest first.
    private var bursts: [ContinuousClock.Instant] = []
    private var stopped = false

    init(limits: HangLimits) { self.limits = limits }

    /// `.ping` with no ping out; `.hangStart` once when the ping is late, with a burst when fewer
    /// than `bursts` bursts came in the last `burstHour`. A tick more than `sleep` of awake time
    /// after the last tick comes after a suspended process, a stalled watchdog, or a timer that App
    /// Nap holds: before a hang start it sends a new ping and writes no line. After a hang start it
    /// keeps the ping, so one hang has one start and one burst.
    mutating func tick(now: HangInstant) -> HangStep? {
        guard !stopped else { return nil }
        defer { lastTick = now }
        if !started, let lastTick, now.awake - lastTick.awake > limits.sleep {
            sent = now
            tickGap = .zero
            return .ping
        }
        guard let sent, let lastTick else {
            self.sent = now
            tickGap = .zero
            return .ping
        }
        tickGap = max(tickGap, now.awake - lastTick.awake)
        let waited = now.awake - sent.awake
        guard !started, waited >= limits.late else { return nil }
        started = true
        let hour = limits.burstHour
        bursts.removeAll { now.continuous - $0 >= hour }
        let burst = bursts.count < limits.bursts
        if burst { bursts.append(now.continuous) }
        return .hangStart(late: waited, tickGap: tickGap, burst: burst)
    }

    /// The answer of the ping: `.hangEnd` after a `.hangStart`, else nil. `slept` is the continuous
    /// time minus the awake time of the hang. `tickGap` counts the answer as the last tick; the
    /// answer of a false start comes before the last tick, so that gap is never under zero.
    mutating func answered(now: HangInstant) -> HangStep? {
        guard !stopped, let sent, let lastTick else { return nil }
        defer {
            self.sent = nil
            started = false
        }
        guard started else { return nil }
        let blocked = now.awake - sent.awake
        return .hangEnd(
            blocked: blocked, slept: max(.zero, now.continuous - sent.continuous - blocked),
            tickGap: max(tickGap, now.awake - lastTick.awake))
    }

    mutating func stop() { stopped = true }
}
