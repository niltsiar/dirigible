import Foundation
import Testing
import os

/// The guard of `Gate.waitOnce`: a wait on a thread of the concurrency pool is an issue, and a
/// wait on another thread holds until `open`. The `until` cases hold the main actor, so they run
/// one at a time: a hold of one case moves the wait of the other.
@Suite(.serialized)
struct GateTests {
    @Test func aGateOnAPoolThreadIsAnIssue() async {
        let gate = Gate()
        // Without the guard, the wait holds until this open, not for 30 s.
        let opener = Task {
            try? await Task.sleep(for: .milliseconds(200))
            gate.open()
        }
        await withKnownIssue {
            await Self.holdOnThePool(gate)
        } matching: { issue in
            issue.comments.contains { $0.rawValue.contains("pool") }
        }
        await opener.value

        let offPool = Gate()
        let done = OSAllocatedUnfairLock(initialState: false)
        DispatchQueue.global(qos: .utility).async {
            offPool.waitOnce()
            done.withLock { $0 = true }
        }
        await offPool.entered(limit: .seconds(5))
        offPool.open()
        await until(limit: .seconds(5), "the wait off the pool did not end") { done.withLock { $0 } }
    }

    /// A main-actor hold over the limit of `until` does not use up the limit (run flakes-2, H1). A
    /// start that ends off the main actor 200 ms after such a hold failed "the take did not
    /// start". The hold and the timer use GCD, so a stall of the concurrency pool does not move
    /// them.
    @Test @MainActor func aMainActorHoldIsOutOfTheUntilLimit() async {
        let done = OSAllocatedUnfairLock(initialState: false)
        var held = false
        await until(limit: .seconds(1), "the condition did not come true") {
            if !held {
                held = true
                DispatchQueue.main.async {
                    Thread.sleep(forTimeInterval: 1.5)
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { done.withLock { $0 = true } }
                }
            }
            return done.withLock { $0 }
        }
    }

    @concurrent private nonisolated static func holdOnThePool(_ gate: Gate) async { hold(gate) }

    private nonisolated static func hold(_ gate: Gate) { gate.waitOnce() }
}
