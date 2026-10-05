import Foundation

/// Measures the time since its start.
struct Stopwatch: Sendable {
    let start = ContinuousClock.now

    /// The time since the start.
    var wall: Duration { ContinuousClock.now - start }

    /// The time since the start.
    var elapsed: Duration { wall }
}
