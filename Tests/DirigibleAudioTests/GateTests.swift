import Foundation
import Testing
import os

/// The guard of `Gate.waitOnce`: a wait on a thread of the concurrency pool is an issue, and a
/// wait on another thread holds until `open`. The `until` cases hold the main actor, so they run
/// one at a time: a hold of one case moves the wait of the other.
@Suite(.serialized)
struct GateTests {
    @Test func aGateOnAPoolThreadIsAnIssue() async {
        let gate = Gate(limit: Gate.openLimit)
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

        let offPool = Gate(limit: Gate.openLimit)
        let done = OSAllocatedUnfairLock(initialState: false)
        DispatchQueue.global(qos: .utility).async {
            offPool.waitOnce()
            done.withLock { $0 = true }
        }
        await offPool.entered(limit: .seconds(5))
        offPool.open()
        await until(limit: .seconds(5), "the wait off the pool did not end") { done.withLock { $0 } }
    }

    /// A hold that times out on a thread of a writer queue has no test, so `open()` records the
    /// miss in the test that opens the gate.
    @Test func aTimedOutHoldIsRecordedWhenTheTestOpensTheGate() async {
        let gate = Gate(limit: .milliseconds(50))
        let ended = OSAllocatedUnfairLock(initialState: false)
        DispatchQueue.global(qos: .utility).async {
            gate.waitOnce()
            ended.withLock { $0 = true }
        }
        await until(limit: .seconds(5), "the hold did not end") { ended.withLock { $0 } }
        withKnownIssue {
            gate.open()
        } matching: { issue in
            issue.comments.contains { $0.rawValue.contains("was not opened") }
        }
    }

    /// A main-actor hold over the limit of `until` does not use up the limit (run flakes-2, H1). A
    /// start that ends off the main actor 200 ms after such a hold failed "the take did not
    /// start". The hold and the timer use GCD, so a stall of the concurrency pool does not move
    /// them. The cap is 60 s: a hold of other suites before this hold (1.5 s or more in a full
    /// suite) would reach the default cap of 3 s.
    @Test @MainActor func aMainActorHoldIsOutOfTheUntilLimit() async {
        let done = OSAllocatedUnfairLock(initialState: false)
        var held = false
        await until(limit: .seconds(1), cap: .seconds(60), "the condition did not come true") {
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

    /// The cap of `until` ends a wait that a hold moved: after a 3 s hold, a 1 s limit (cap 3 s)
    /// checks twice and records the issue. With no cap, it polls for 1 s more. The count of checks
    /// does not change with the load, a wall time does.
    @Test @MainActor func aHoldPastTheCapEndsTheUntilWait() async {
        let ended = OSAllocatedUnfairLock(initialState: false)
        var held = false
        var checksAfterTheHold = 0
        await withKnownIssue {
            await until(limit: .seconds(1), "the condition is never true") {
                if !held {
                    held = true
                    DispatchQueue.main.async {
                        Thread.sleep(forTimeInterval: 3)
                        ended.withLock { $0 = true }
                    }
                }
                if ended.withLock({ $0 }) { checksAfterTheHold += 1 }
                return false
            }
        }
        #expect(checksAfterTheHold <= 2, "checks after the hold: \(checksAfterTheHold)")
    }

    /// The attach poll of `SyntheticInput` runs on its own thread while a take start waits behind
    /// a main-actor hold. The hold does not use up its limit: an attach after a 3 s hold is found
    /// with a 2 s limit. The cap is 60 s, as in `aMainActorHoldIsOutOfTheUntilLimit`.
    @Test @MainActor func aMainActorHoldIsOutOfTheAttachPollLimit() async {
        _ = MainActorHolds.shared.total
        let attached = OSAllocatedUnfairLock(initialState: false)
        DispatchQueue.main.async {
            Thread.sleep(forTimeInterval: 3)
            attached.withLock { $0 = true }
        }
        let found = await withCheckedContinuation { continuation in
            Thread {
                continuation.resume(
                    returning: SyntheticInput.poll(limit: .seconds(2), cap: .seconds(60)) {
                        attached.withLock { $0 } ? true : nil
                    })
            }.start()
        }
        #expect(found == true, "the attach after the hold was not found")
    }

    /// A stopwatch leaves a main-actor hold of other suites out of its elapsed time, so a
    /// wall-time assert does not fail on a hold (run flakes-2, S4).
    @Test @MainActor func aStopwatchLeavesAMainActorHoldOut() async {
        let watch = Stopwatch()
        DispatchQueue.main.async { Thread.sleep(forTimeInterval: 1.5) }
        try? await Task.sleep(for: .milliseconds(10))

        #expect(watch.wall >= .seconds(1.5))
        #expect(watch.elapsed < .seconds(1), "elapsed \(watch.elapsed)")
    }

    @concurrent private nonisolated static func holdOnThePool(_ gate: Gate) async { hold(gate) }

    private nonisolated static func hold(_ gate: Gate) { gate.waitOnce() }
}
