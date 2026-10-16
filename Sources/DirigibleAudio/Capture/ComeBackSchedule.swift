/// When a lost writer tries to attach again (decision 0013), with the time as a parameter. A
/// writer whose last try did not fail tries at the first device-list event. After a failed try,
/// the next try waits for the end of a backoff window: 250 ms, doubled after each failed try, and
/// at most `retryInterval`. An event in the window sets one pending try, which the drain tick runs
/// when the window ends. A try that finds no device opens no window. With no event, the tick tries
/// each `retryInterval`.
struct ComeBackSchedule {
    /// How a try ended. A failed try made or called a HAL object (a tap, the attach), and its
    /// device-list events must not feed more tries. An absent try made none.
    enum Outcome { case attached, failed, absent }

    static let firstBackoff = Duration.milliseconds(250)
    static let retryInterval = Duration.seconds(1)

    /// The loss, or the last try.
    private var lastTry: ContinuousClock.Instant
    /// The window after the last failed try: its end and its length. Nil after an attach.
    private var window: (end: ContinuousClock.Instant, length: Duration)?
    private var pending = false

    init(at now: ContinuousClock.Instant) { lastTry = now }

    /// The writer is lost at `now`. The tick tries at `now` + `retryInterval`.
    mutating func lost(at now: ContinuousClock.Instant) {
        lastTry = now
    }

    /// A try at `now` ended with `outcome`. An absent try keeps the window of the last failed try.
    mutating func tried(_ outcome: Outcome, at now: ContinuousClock.Instant) {
        lastTry = now
        pending = false
        switch outcome {
        case .attached:
            window = nil
        case .failed:
            let length = window.map { min($0.length * 2, Self.retryInterval) } ?? Self.firstBackoff
            window = (now + length, length)
        case .absent:
            break
        }
    }

    /// A device-list event at `now` of a lost writer. True: try now.
    mutating func event(at now: ContinuousClock.Instant) -> Bool {
        guard let window, now < window.end else { return true }
        pending = true
        return false
    }

    /// A drain tick at `now` of a lost writer. True: try now.
    func tick(at now: ContinuousClock.Instant) -> Bool {
        if pending, let window { return now >= window.end }
        return now - lastTry >= Self.retryInterval
    }
}
