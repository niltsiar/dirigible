# Waits, limits, and held work

## Give every wait a limit

- Give every wait in a test (a poll loop, a yield loop, a child process) a limit and a failure message. When a bug or a mutation removes the state that the test waits for, the test must fail, not hang the suite.
- The limit belongs to the wait of the test, not to the work that the test holds. A gate that holds product work has no limit, and a `defer` releases it on every exit of the test. A hold with its own timeout ends when the test is slow under load, and the test fails on a wrong assert, not on its limit message.
- Compute one deadline per public call and pass it down to each nested wait: limits per step add up. An expired limit never continues into the success path.
- Prove the failure message with a mutation that forces the miss, and read the message in the output. A shorter outer limit hides the message of an inner wait.
- Keep every limit below the time of one full suite run: a longer limit cannot find a hang.
- A change to a display or run-loop callback (`updateLayer`, `draw(_:)`, `layout`) can loop on the main thread, and then no limit in the test fires. Run such a test the first time in the background or with an outer limit. When it hangs, find the loop with `pgrep -fl swiftpm-testing-helper` and `sample <pid> 1` before you change the code. Make its control with `mutate.py --timeout`.

## Wait for a signal, not for time

- A test that acts on an asynchronous milestone (the writer is attached, the job runs, the progress shows) waits for a signal from the code, or holds the state with a gate. A test that needs the work to be slower than its poll fails in a faster suite.
- A fixed count of `Task.yield()` calls or a sleep is a clock too: each yield waits behind the main-actor jobs of other suites. Expose the state from the code (for example the count of waiters in a queue) and wait on it with a limit.
- If a wait fails because an actor or a serial queue is busy, name the code that holds it before you change a limit (`flake-triage.md` in this folder gives the monitor).
- Make each producer, timer, and watchdog of the test run longer than the wait limit of the step where the test stops it, not its expected time, and end it explicitly (for example with a detach). The limit clock starts only after the hop to the wait, and a hop under load can take longer than the margin. So a product watchdog in a test gets a value or a clock that the test controls. Assert only the property ("before the full duration") with a wide margin, never "promptly". Fix every test that uses the same duration in one commit.

## Stops, threads, and OS resources

- A test of a cancel or a stop asserts that no work happens after it (no progress call, no write, no next chunk). An end state such as "cancelled, no file" also passes when a later check stops the work, so it cannot fail when the earlier guard goes.
- A hook that asserts where work runs (the thread or the actor) is synchronous and sits at the operation, for example right after the file read. A hook in a nearby async or nonisolated closure reports the isolation of that closure, so it passes when the operation moves to the main actor.
- A hook that asserts a priority reads `Task.currentPriority` at the operation, also on a GCD thread. `qos_class_self()` gives only the requested QoS and misses the escalation when a caller with a higher priority awaits `task.value` of a detached task.
- A script or a test that holds an OS resource (a mount, a child process, a temporary folder) ends its committed check with an assert that the resource is gone. A tolerant cleanup (`|| true`, "detach only when still attached") turns a failure into a silent leak. Resolve both paths with `pwd -P` before a compare: `mktemp -d` gives `/var/folders/...`, and `mount` prints `/private/var/folders/...`.
