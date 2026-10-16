import Atomics

/// The start state and the stop time of one writer (decision 0030). Any thread reads and writes
/// them: atomics only, so a stop never waits for the writer queue to set them.
final class WriterLifecycle: Sendable {
    enum Start: UInt8, AtomicValue {
        case notAttached, attached, abandoned
    }

    private let start = ManagedAtomic(Start.notAttached)
    private let endHost = ManagedAtomic<UInt64>(.max)

    var state: Start { start.load(ordering: .acquiring) }

    /// A successful attach. Returns the start state before it: `.notAttached` for the first
    /// attach, `.attached` for a later one, and `.abandoned` when the stop gave up the writer
    /// first. Then the attach tears down and writes nothing.
    func attach() -> Start {
        let (exchanged, original) = start.compareExchange(
            expected: .notAttached, desired: .attached, ordering: .acquiringAndReleasing)
        return exchanged ? .notAttached : original
    }

    /// The stop gives up a writer that never attached. False when an attach came first.
    func abandon() -> Bool {
        start.compareExchange(expected: .notAttached, desired: .abandoned, ordering: .acquiringAndReleasing).exchanged
    }

    /// The host time at or after which the writer writes no record. The lowest call wins.
    var endHostNanos: UInt64 { endHost.load(ordering: .acquiring) }

    func end(atHostNanos end: UInt64) {
        var current = endHost.load(ordering: .acquiring)
        while end < current {
            let (exchanged, original) = endHost.weakCompareExchange(
                expected: current, desired: end, ordering: .acquiringAndReleasing)
            if exchanged { return }
            current = original
        }
    }
}
