/// A9: the silence check of an app track, by record host time. After 5.0 s of zeros while a
/// matched process plays, it warns; it rebuilds the tap at the warning, 10 s after it, and 40 s
/// after it, at most 3 times for the life of the check. A take counts the zeros from the first
/// drain with a matched process, and its first sample that is not zero ends it. A monitor
/// counts them from the start of the current playing run: the first record of the drain where
/// the playing flag reads true after false, or the first record after a rebuild that is not a
/// silence step. Both rearm it (`rearm()`). It reads the playing flag at most once for each
/// second of records: a take only when a step is due, a monitor at each read.
struct SilenceCheck {
    enum Rule { case take, monitor }

    /// The zeros before the warning.
    static let limit: UInt64 = 5_000_000_000
    /// The rebuilds after the warning.
    static let rebuilds: [UInt64] = [atWarning, 10_000_000_000, 40_000_000_000]
    /// The first rebuild comes with the warning.
    static let atWarning: UInt64 = 0
    static let readInterval: UInt64 = 1_000_000_000

    let rule: Rule
    /// True after a routed sample that is not zero since the start of the zeros.
    private(set) var heard = false
    /// The host time of the start of the zeros.
    private var start: UInt64?
    /// The host times of the first and the last record of the last drain.
    private var first: UInt64?
    private var last: UInt64?
    private(set) var warnedAt: UInt64?
    /// The steps of the schedule since the start of the zeros.
    private var steps = 0
    /// The silence rebuilds for the life of the check.
    private var rebuilt = 0
    /// A monitor: the last read of the playing flag.
    private var playing = false
    private var nextRead: UInt64 = 0

    init(_ rule: Rule = .take) { self.rule = rule }

    /// True while the track shows the warning: it warned and no sound came.
    var warns: Bool { warnedAt != nil && !heard }

    /// The journal cause of the last rebuild: the seconds of zeros before it, for example
    /// `silence-15s`. Only after a rebuild of `due`.
    var rebuildCause: String { "silence-\((Self.limit + Self.rebuilds[steps - 1]) / 1_000_000_000)s" }

    /// Takes one drain: the host times of its first and last records, whether a routed sample
    /// was not zero, and whether the tap has a matched process.
    mutating func take(firstHost: UInt64, lastHost: UInt64, heard: Bool, hasProcess: Bool) {
        if heard { self.heard = true }
        if start == nil, hasProcess, rule == .take || playing { start = firstHost }
        first = firstHost
        last = lastHost
    }

    /// A monitor after a new playing run or a rebuild that is not a silence step: no warning,
    /// not heard, and a new start of the zeros. It keeps the count of silence rebuilds. A take
    /// does not rearm.
    mutating func rearm() {
        guard rule == .monitor else { return }
        heard = false
        warnedAt = nil
        start = nil
        steps = 0
    }

    /// The warning and the rebuild that are due now. `playing` reads the app.
    mutating func due(playing read: () -> Bool) -> (warn: Bool, rebuild: Bool) {
        switch rule {
        case .take:
            guard !heard, let start, let last, steps < Self.rebuilds.count else { return (false, false) }
            guard last &- (warnedAt ?? start) >= wait, last >= nextRead else { return (false, false) }
            nextRead = last &+ Self.readInterval
            guard read() else { return (false, false) }
        case .monitor:
            guard let first, let last, last >= nextRead else { return (false, false) }
            nextRead = last &+ Self.readInterval
            let now = read()
            defer { playing = now }
            guard now else { return (false, false) }
            if !playing {
                rearm()
                start = first
            }
            guard !heard, let start, steps < Self.rebuilds.count, last &- (warnedAt ?? start) >= wait else {
                return (false, false)
            }
        }
        let warn = warnedAt == nil
        if warn { warnedAt = last }
        steps += 1
        let rebuild = rebuilt < Self.rebuilds.count
        if rebuild { rebuilt += 1 }
        return (warn, rebuild)
    }

    /// The zeros before the next step.
    private var wait: UInt64 { warnedAt == nil ? Self.limit : Self.rebuilds[steps] }
}
