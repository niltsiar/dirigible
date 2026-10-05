import Foundation

/// The main-actor time that other suites hold. In a full suite, the `@MainActor` suites hold the
/// main actor for up to 18.8 s, spread over many suites (run flakes-2, S4). A main-actor task
/// sleeps 10 ms in a loop, and a sleep that returns more than 1 s late adds its lag. A product
/// hold over 1 s is left out too, so the product budgets measure the wall time.
final class MainActorHolds: @unchecked Sendable {
    static let shared = MainActorHolds()
    private let lock = NSLock()
    private var held = Duration.zero
    private var asleep = ContinuousClock.now

    private init() {
        Task { @MainActor [self] in
            while true {
                try? await Task.sleep(for: .milliseconds(10))
                lock.withLock {
                    held += Self.lag(since: asleep)
                    asleep = .now
                }
            }
        }
    }

    /// The held time so far, with a hold that runs now.
    var total: Duration { lock.withLock { held + Self.lag(since: asleep) } }

    private static func lag(since asleep: ContinuousClock.Instant) -> Duration {
        let lag = ContinuousClock.now - asleep - .milliseconds(10)
        return lag > .seconds(1) ? lag : .zero
    }
}

/// Measures the time since its start, with or without the main-actor holds of other suites.
struct Stopwatch: Sendable {
    let start = ContinuousClock.now
    private let heldAtStart = MainActorHolds.shared.total

    /// The time since the start.
    var wall: Duration { ContinuousClock.now - start }

    /// The time since the start, less the main-actor holds since the start.
    var elapsed: Duration { wall - (MainActorHolds.shared.total - heldAtStart) }
}
