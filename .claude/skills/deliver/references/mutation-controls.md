# Mutation pass

The red-first log of each slice is its control (tdd steps 4 and 7), at each risk level. No mutation control runs at slice time, and no control replays. A `risk: yes` run gets one mutation pass in Phase 7; a `risk: no` run gets none. The docstring of `.claude/skills/deliver/scripts/mutate.py` gives each flag and each result line.

## Pick the mutants

- Run the pass once, on the landing tree: after the last code gate fix and the last Phase 7 fix, before the push check. A killed mutant does not run again.
- One agent reads the diff, the criteria, and the probe results. It picks one mutant per risk guard on the changed lines: at least 3, at most 6.
- Prefer a removed check, a guard operator or boundary, and a constant that a probe measured. Skip logging, waits, time limits, speed (the bench owns it), UI strings, and framework setup order.
- Always pick each data-safety guard of the AGENTS.md Safety rules, in the direction that loses data.
- The mutant breaks the mechanism of the claim (a removed guard, a relaxed memory order). A mutant that only corrupts the input of the checker proves only the checker.
- Run each mutant under the exact conditions of the claim. Turn on a condition that is off (a compiler feature) with a temporary change that you revert.

## Run the pass

- Write each mutant as one `mutant <file> <old> <new> <log> <build> <test>` line (the arguments of mutate.py) of a batch file in the run folder. Run `.claude/skills/deliver/scripts/mutation-pass.sh <worktree> <batch file>` once, with `run_in_background`: it holds the build lock once for the batch, and puts no sleep between two mutants.
- The build command is `scripts/with-lock.sh swift build --build-tests`. The test command is `scripts/test-filter.sh --skip-build --exact <name>`: no second build, and no XCTest pass.
- A mutant with two edits (a guard mutant and the fault that trips it) is one call with two old/new pairs. Put `--in=<file>` before the pairs of a second file. Never apply an edit with a script in the build or test command.
- Do not nest mutate.py in its test command. After `NO TESTS` or `BUILD FAILED`, correct the filter or the mutant and run it again.
- Warnings are errors, so mutate the source of a value, not the place that uses it.
- Pass the assertion message of the killing test with `--expect <text>`, not a test name. A guard and its refusal message read the limit from one variable.
- Pass `--timeout <seconds>`, a few times the green test time. A crash or a thrown error before the assert gives `WRONG FAILURE`, so the mutant keeps the type and shape of the data that later code reads.
- mutate.py restores only the source file, from a hash-checked copy, never from git. So the build command first deletes or builds again each shared output that its test reads.
- A test command that acts on shared state (Mission Control, HID events, a probe) runs only when no other agent uses the screen. A test command that writes output (a session, a capture) gets a new folder on each run, for example `<run>/x-$(date +%s)`.
- Save each log under `<run>/controls/`, and cite it in a phase 7 `decisions.tsv` row: the pass row. With `risk: yes`, `scripts/land.sh` refuses a run with no pass row, unless its third argument names the row that says why no pass applies.

## Read each survivor

- The lead reads each survivor, also run with `DIRIGIBLE_SLOW_TESTS=1`, and logs it with the result `survived`. A second agent checks each claim that a mutant is equivalent.
- Equivalent: no caller can reach the mutated behavior. Log the caller reason in `decisions.tsv`, and stop. A probe that measured one effect of the mutant is not a caller reason.
- Misaimed: the mutant does not reach the planned path. Fix the mutant once.
- Each other survivor is the red step of a new test. Write the test; the killed log is its proof.
- When only the test process has the mechanism that hides the mutant (Return reaches a list action there that a real Return does not), retire the mutant with that reason in `decisions.tsv`, and prove the path on the built app. Never change a product mechanism only so that a mutant can kill it.

## Measure

For the next 5 `risk: yes` runs, log each pick, its result, and its time. When a code gate or a check of the built app finds a defect that a skipped guard mutant would kill, go back to one mutant per guard.
