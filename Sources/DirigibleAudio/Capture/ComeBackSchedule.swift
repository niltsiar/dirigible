/// When a lost writer tries to attach again (decision 0013), with the time as a parameter. A
/// writer whose last try did not fail tries at the first device-list event. After a failed try,
/// the next try waits for the end of a backoff window: 250 ms, doubled after each failed try, and
/// at most `retryInterval`. An event in the window sets one pending try, which the drain tick runs
/// when the window ends. With no event, the tick tries each `retryInterval`.
struct ComeBackSchedule {
    static let firstBackoff = Duration.milliseconds(250)
    static let retryInterval = Duration.seconds(1)

    /// The loss, or the last try.
    private var lastTry: ContinuousClock.Instant
    /// The window after the last failed try. Nil when the last try did not fail.
    private var backoff: Duration?
    private var pending = false

    init(at now: ContinuousClock.Instant) { lastTry = now }

    /// The writer is lost at `now`. The tick tries at `now` + `retryInterval`.
    mutating func lost(at now: ContinuousClock.Instant) {
        lastTry = now
    }

    /// A try at `now` did not attach.
    mutating func failed(at now: ContinuousClock.Instant) {
        lastTry = now
        backoff = backoff.map { min($0 * 2, Self.retryInterval) } ?? Self.firstBackoff
        pending = false
    }

    /// A try attached: the next loss tries at its first event.
    mutating func attached() {
        backoff = nil
        pending = false
    }

    /// A device-list event at `now` of a lost writer. True: try now.
    mutating func event(at now: ContinuousClock.Instant) -> Bool {
        guard let backoff, now - lastTry < backoff else { return true }
        pending = true
        return false
    }

    /// A drain tick at `now` of a lost writer. True: try now.
    func tick(at now: ContinuousClock.Instant) -> Bool {
        now - lastTry >= (pending ? backoff ?? .zero : Self.retryInterval)
    }
}
