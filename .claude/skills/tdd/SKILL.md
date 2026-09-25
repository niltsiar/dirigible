---
name: tdd
description: "Write the failing test first, then the code. Use for every behavior change in this repo: a new feature slice, a bug fix, or a regression test. Prefer an integration test that drives the real module with real files and real audio buffers."
---

# Test-first delivery

Make the intended behavior executable before you change production code. The test fails before the change and passes after it.

This repo prefers integration tests over unit tests. An integration test calls a module through its public API, the same way the app calls it, with real inputs: real WAV or FLAC files on disk, real `AVAudioPCMBuffer` data, real session XML. Write a unit test only for a pure function with many edge cases, where an integration test would be slow or hide the failing case.

## Workflow

1. **Understand the behavior.** Identify the intended behavior, the current behavior, the affected path, and the smallest observable result.
2. **Choose the check.** Prefer the integration test target of the module that owns the behavior. Generate audio fixtures in the test (a sine tone, silence, white noise at a known level) instead of committing large binary files.
3. **Write the failing test first.** The test encodes intended behavior, not the current implementation. Assert a literal expected value or an observable effect: a file on disk, a sample count, a level in dBFS within a stated tolerance, a parsed XML element.
4. **Run the new test before the fix.** Confirm that it fails for the intended reason. If it passes, or fails for an unrelated reason, correct the test first.
5. **Make the change.** Write the smallest production change that satisfies the test.
6. **Rerun the test and the full suite.** Run `make test`. Confirm the new test passes and nothing else broke.
7. **Commit in order.** When the change is a bug fix, you can commit the failing test first (`test:`) and the fix on top (`fix:`). For a feature, commit the test and the code together (`feat:`).

## If a failing test is impractical

Some behavior needs hardware: a real microphone, two physical audio interfaces, a permission prompt. Do not silently skip the regression step. Before the change, explain why an automated test is impossible, then pick the closest executable check: an offline render, a virtual device, a script that records five seconds and prints the file facts with `afinfo` or `ffprobe`. Record the manual check in the run ledger so a human can repeat it.

Prefer no new test over a bad test. A bad test mostly tests mocks, encodes implementation details, depends on timing or global state, or would still pass if every function it calls returned nothing.

## Guardrails

- Do not change tests to match a wrong implementation.
- Do not weaken existing assertions unless the expected behavior changed, and say why.
- Audio comparisons use a stated tolerance, never exact float equality on processed samples.
- For a writer and reader pair, add one seeded random round-trip test beside the literal tests. Build values through the public edits, write, read, and assert `==`. It tests the claim "every value an edit accepts, the reader accepts".
- Give every wait in a test a limit and a failure message: a poll loop, a yield loop, a child process. When a bug or a mutation removes the state that the test waits for, the test must fail, not hang the suite.
- If a test is flaky, make it deterministic or delete it. Do not retry until green. First run the full suite and the test alone, 15 times each. When only the full suite fails, look for a process-wide resource in the code under test: a file descriptor, a lock, a temporary path, an environment variable, the main actor, a serial queue, the threads of the Swift concurrency pool, a user preference of the Mac (for example window tabbing). Parallel tests share these. A synchronous wait (a semaphore) in async test code blocks a pool thread, so use an awaitable gate with a limit. Pin a user preference that a test depends on before the test opens a window. Delete the test only when the cause is in the test itself. Commit a flake fix only after the failing command passes as many times in a row as it took to expose the failure. A process sample that shows the holder gone is not proof.
- If a wait fails because an actor or a serial queue is busy, name the code that holds it before you change a limit. Sample the process during the full suite. Write the holder in `decisions.tsv`. When product code holds it, it is a finding against the plan, not a test fix. When test code holds it (for example file writes in the `init` of a `@MainActor` suite), move that work off the actor first. When no single piece of code holds it and the load of other tests does (GB writes, child processes, disk images), run those tests in a separate process. Keep every limit below the time of one full suite run; a longer limit cannot find a hang. Then make every producer, timer, and watchdog of the test run longer than the step where the test stops it. Assert only the property ("before the full duration") with a wide margin, never "promptly". Search for every test that uses the same duration and fix all of them in one commit.

## Final response

- Name the failing-before test and the failure it produced.
- Name the passing-after run (`make test`) and its result.
- If failing-before evidence was impossible, state why and name the closest check you used.
