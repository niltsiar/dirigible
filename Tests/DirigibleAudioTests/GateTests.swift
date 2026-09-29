import Foundation
import Testing
import os

/// The guard of `Gate.waitOnce`: a wait on a thread of the concurrency pool is an issue, and a
/// wait on another thread holds until `open`.
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

    @concurrent private nonisolated static func holdOnThePool(_ gate: Gate) async { hold(gate) }

    private nonisolated static func hold(_ gate: Gate) { gate.waitOnce() }
}
