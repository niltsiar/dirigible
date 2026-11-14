---
name: tdd
description: "Write the failing test first, then the code. Use for every behavior change: a feature slice, a bug fix, or a regression test."
---

# Test-first delivery

Prefer an integration test: call a module through its public API with real inputs (WAV or FLAC files on disk, `AVAudioPCMBuffer` data, session XML). Write a unit test only for a pure function with many edge cases, where an integration test would be slow or hide the failing case.

## Workflow

1. **Understand the behavior.** Name the intended and the current behavior, the affected path, and the smallest observable result.
2. **Choose the check.** Prefer the integration test target of the module that owns the behavior. Generate audio fixtures in the test (a sine tone, silence, noise at a known level), not large binary files. This command lists the shared test helpers to reuse: `git ls-files 'Tests/*.swift' | grep -vE '(Tests|Benchmark)(\+\w+)?\.swift$' | xargs grep -nE '^ {0,4}([@a-zA-Z]+ )*(func|class|struct|actor|enum|extension) '`. A criterion and its test use the field case of the report; a reader of files that already exist gets one case for each form in the real files, found with `rg` before the first test.
3. **Write the failing test first.** The test encodes intended behavior, not the current implementation. Assert a literal value or an observable effect: a file on disk, a sample count, a level in dBFS within a stated tolerance, a parsed XML element. Derive a value that the user reads in a sentence ("less than N min") from that sentence, not from a review fix, and test its exact boundary. A test of a text that names values (an enum case, a role, a tool name) asserts, for each value, the words that the text says about it, not only a prefix or a subset of the names. Test each start state that the criteria name (**deliver** Phase 1). Read `references/test-harness.md` when the test drives the UI, compares a `CGFloat`, or holds the pool, a preference, or a seam.
4. **Run the new test before the fix.** A compile error is the red of a new function. A red stub builds with no warning (**No warnings** in `CODING_STANDARDS.md`): it uses each value that it declares. A bug fix shows the fault itself: the wrong value or the crash. Correct a test that fails for another reason. Save the red output to a log.
5. **Make the smallest production change** that satisfies the test.
6. **Run the slice tests:** `scripts/with-lock.sh make check-changed FILTER='<names> <tests of the slice>' > <run>/logs/<name>.log 2>&1`: red before the fix, green after it. Take the names from the `filter:` line of `scripts/check-changed.sh`; a FILTER that omits one exits 3. The push check runs all tests.
7. **Commit.** A failing test and its fix go in one commit, with the red log path in `decisions.tsv`.

## No failing test

When the behavior needs hardware (a microphone, two audio interfaces, a permission prompt), explain before the change why an automated test is impossible. Use the closest executable check: an offline render, a virtual device, or a script that records five seconds and prints the file facts (`afinfo`, `ffprobe`).

Prefer no new test over a bad test: one that mostly tests mocks, encodes implementation details, depends on timing or global state, or still passes when every function it calls returns nothing.

## Guardrails

- Tests do not use the network, the real microphone, or a permission prompt. Use a fixture file or an offline render in place of the microphone. Inject the network or permission state through a seam.
- Change a test or weaken an assertion only when the expected behavior changed, and say why. A wrong implementation is never the reason.
- Compare two large values into a `Bool` with a short message: a failed `#expect` or `#require` prints both values and can hang the run.
- When a test refuses or blocks a user action, also assert that the user input stays (typed text, open alert, selection, clipboard). "The model did not change" alone passes when the input is lost. If the plan expects lost input, raise a plan finding in place of the test.
- A test that expects a refusal (a nonzero exit, a throw, a refused edit) also asserts its reason (the rule message or error case): a broken fixture also fails.
- Assert that a refused path does not exist after the call. The script refuses it before its first side effect (`mkdir -p`), and resolves it again (`pwd -P`) after it.
- Take no expected value from the code under test (a copied literal, the same call). Resolve an expected path with `realpath`.
- A test that asserts "nothing changed after X" first proves, in the same observation, that X reached the output. A wait or sleep passes when X never happened. A test of "X during Y" also asserts that Y goes on.
- A test that asserts unchanged files compares the bytes or a hash of each file, not names, sizes, or dates: the likely damage is a rewrite in place with the same size. Its control changes one byte at a fixed offset.
- Compare processed audio with a stated tolerance, never exact float equality.
- Put a slow test behind `DIRIGIBLE_SLOW_TESTS=1`. `scripts/with-lock.sh make test-slow` runs it.
- A test that reads a member that `Sources/` declares only under `#if DEBUG` sits in `#if DEBUG` too: `scripts/bench.sh` builds the tests with no DEBUG. `scripts/check-waits.sh` finds a use by name.
- Add one seeded random test beside the literal tests, with values built through the public edits and no new library: the round-trip (write, read, `==`) for a writer and reader pair; else its strongest property: inverse (edit, then undo), invariant (output under a limit), or oracle (a simpler reference).
- Read `references/waits-and-limits.md` when a test waits, sets a product timer, holds a gate or OS resource, stops work, or asserts a thread or priority.
- Read `references/flake-triage.md` first when a test fails on each full-suite run but passes alone, fails only sometimes, or fails with other wait-limit failures, or when you change a shared helper or the suite speed.
- A wrong value in a test of code that the run changed is a bug. Use the **diagnosing-bugs** skill, not the flake triage.

## Final response

- Name the failing-before test and its failure, and the passing-after tests of the slice and their result.
- If failing-before evidence was impossible, state why and name the closest check.
