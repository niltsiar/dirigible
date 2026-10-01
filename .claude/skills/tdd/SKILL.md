---
name: tdd
description: "Write the failing test first, then the code. Use for every behavior change: a feature slice, a bug fix, or a regression test."
---

# Test-first delivery

Write the test first: it fails before the change and passes after it.

Prefer an integration test: call a module through its public API with real inputs (WAV or FLAC files on disk, `AVAudioPCMBuffer` data, session XML). Write a unit test only for a pure function with many edge cases, where an integration test would be slow or hide the failing case.

## Workflow

1. **Understand the behavior.** Name the intended and the current behavior, the affected path, and the smallest observable result.
2. **Choose the check.** Prefer the integration test target of the module that owns the behavior. Generate audio fixtures in the test (a sine tone, silence, noise at a known level), not large binary files.
3. **Write the failing test first.** The test encodes intended behavior, not the current implementation. Assert a literal expected value or an observable effect: a file on disk, a sample count, a level in dBFS within a stated tolerance, a parsed XML element. Derive a value that the user reads in a sentence ("less than N min") from that sentence, not from a review fix, and test its exact boundary. Test a trigger (a command, a key) in each start state: the window closed or shown, the focus in each control. Read `references/test-harness.md` when the test drives the UI, compares a `CGFloat`, or holds the pool, a preference, or a seam.
4. **Run the new test before the fix.** Confirm that it fails for the intended reason, or correct the test first. Save the red output to a log.
5. **Make the smallest production change** that satisfies the test.
6. **Run the full suite.** Confirm with `make test` that the new test passes and nothing else broke.
7. **Commit.** A failing test and its fix go in one commit (`feat:` or `fix:`), with the path of the red log in `decisions.tsv`.

## No failing test

When the behavior needs hardware (a microphone, two audio interfaces, a permission prompt), explain before the change why an automated test is impossible. Use the closest executable check: an offline render, a virtual device, or a script that records five seconds and prints the file facts (`afinfo`, `ffprobe`).

Prefer no new test over a bad test: one that mostly tests mocks, encodes implementation details, depends on timing or global state, or still passes when every function it calls returns nothing.

## Guardrails

- Change a test or weaken an assertion only when the expected behavior changed, and say why. A wrong implementation is never the reason.
- Compare two large values into a `Bool` with a short message: on a failure, `#expect` or `#require` prints both values and can hang the run.
- When a test refuses or blocks a user action, also assert that the user input stays: the typed text, the open alert, the selection, the clipboard. "The model did not change" alone passes when the input is lost. If the plan expects lost input, raise a plan finding in place of the test.
- A test that expects a refusal (a nonzero exit, a thrown error, a refused edit) also asserts its reason (the rule message or the error case): a broken fixture also fails.
- A refusal of a path also asserts that the path does not exist afterwards. The script checks before its first side effect (a `mkdir -p`), and resolves the path again (`pwd -P`) after it makes it.
- A test that asserts "nothing changed after X" first proves, in the same observation, that X reached the output (for example a changed control region of the capture). With only a wait or a sleep, it passes when X never happened.
- A test that asserts unchanged files compares the full bytes or a hash of each file, not names, sizes, or dates: the likely damage is a rewrite in place with the same size. Its control changes one byte at a fixed offset.
- Compare processed audio with a stated tolerance, never exact float equality.
- For a writer and reader pair, add one seeded random round-trip test beside the literal tests: build values through the public edits, write, read, and assert `==`.
- Read `references/waits-and-limits.md` when a test waits, holds a gate or an OS resource, stops work, or asserts a thread or a priority.
- Read `references/flake-triage.md` when a test fails only sometimes or in a cluster of wait-limit failures, or when you change a shared test helper or the suite speed.

## Final response

- Name the failing-before test and its failure, and the passing-after `make test` run and its result.
- If failing-before evidence was impossible, state why and name the closest check.
