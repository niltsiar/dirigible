# Flake triage

## Run the triage first

If a test is flaky, run this triage first, in this order:

1. Record in `decisions.tsv` the load average at the failure and the heavy commands just before it (disk images, benches, builds in another worktree). When the load was high, run the loops of step 2 under that load source: start it, wait until `uptime` shows its load, and pass `--min-load <n>` to `scripts/flake-monitor/loop.sh`. A source that makes no load gives the numbers of a quiet loop.
2. Run the full suite and the test alone, 15 times each.
3. For a flake on a limit (a timeout or a hang guard), compare the duration of the test with its limit on the branch and on `main` in each loop run. A time near the limit on `main` shows a flake of `main`. A pass count alone decides nothing.
4. Repeat the same loops on `main`. A new flake is "outside the run" only after they pass on `main`. "The diff does not touch the test" and a backlog watch line are not a triage.

## Find the cause

- Make the flaky test deterministic, or delete it when the cause is in the test itself. Do not retry until green.
- When only the full suite fails, first read the diff of the slice where the flake first came, with its test helpers, hooks, and gates. New test code can hold a shared resource, also when the failing test does not touch the changed code.
- Look for a process-wide resource in the code under test and in the test code: a file descriptor, a lock, a temporary path, an environment variable, the main actor, a serial queue, the threads of the Swift concurrency pool, a user preference of the Mac, the key window. Parallel tests share these. `test-harness.md` in this folder gives the fixes for the key window, the pool, preferences, and seams.
- When a red run is a cluster of unrelated wait-limit failures, find the holder with a monitor, not more repeat runs. Add a monitor test to the full suite. Every 100 ms it times a pool hop (`await Task.detached {}.value`) and a main-actor hop (`await MainActor.run {}`). When a hop waits longer than 2 s, a thread outside the pool runs `/usr/bin/sample <pid> 2` to show the frames of the holders. Write the holder in `decisions.tsv`.
- When product code holds it, it is a finding against the plan, not a test fix. When test code holds it (for example file writes in the `init` of a `@MainActor` suite), move that work off the actor. When the load of other tests holds it (GB writes, child processes, disk images), run those tests in a separate process.
- A change to a shared test helper or to the suite speed changes the timing of every test. After such a change, search every suite for the shape it exposes, not only the suites of the run.

## Prove the fix

- A test moved behind the slow gate, a longer limit, or a smaller fixture is a workaround that weakens a gate. Log it as open in `decisions.tsv`. After the root-cause fix, undo it and prove the undo with the same loop.
- The proof of a flake fix is a mutation that reproduces the exact failure value of the flake: red on the old code, green on the new code. A saturated value (silence, a guard that fired) comes from every cause that trips the same guard.
- Then show a threshold: fill the suspected resource on purpose (as many holders as the pool is wide, held past the limit), and stay green one step under it (one holder fewer, or a shorter hold). The test and the test runner need that resource too, so prove the hold with a measurement after it (the time past the limit), not with a wait or an assert during it.
- Commit a flake fix only after the failing command passes as many times in a row as it took to expose the failure. That loop is a regression check, not a proof, and a process sample that shows the holder gone is not a proof either.
