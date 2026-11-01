# Mutation pass

The red-first log of each slice and each fix is its control (tdd steps 4 and 7), at each risk level. No mutation control runs at slice time, and no control replays. A `risk: yes` run gets one mutation pass in Phase 7; a `risk: no` run gets none. The docstring of `.claude/skills/deliver/scripts/mutate.py` gives each flag and each result line.

## Pick the mutants

- Run the pass once, each mutant with `--timeout`, on the landing tree: after the last code gate fix and the last Phase 7 fix, before the push check. A killed mutant does not run again. A fix after the pass runs one new mutant for each guard that it touched, on its changed line; no other mutant runs again. When the fix touches no guard, log a phase 7 row that says so, and give its time to `scripts/land.sh`, which refuses a pass row older than the last `Sources/` commit.
- One agent reads the diff, the criteria, and the probe results. It picks one mutant for each data-safety guard of **Safety** in `CODING_STANDARDS.md` on the changed lines, in the direction that loses data, with no cap. Then it adds one mutant for each other risk guard on the changed lines while the total is under 6. With fewer than 3, it adds another direction of the riskiest guard until there are 3 or no direction is left. With no guard on the changed lines, log a phase 7 row that says why no pass applies, and give its time to `scripts/land.sh`.
- Prefer a removed check, a guard operator or boundary, and a constant that a probe measured. Skip logging, waits, time limits, speed (the bench owns it), UI strings, and framework setup order.
- The mutant breaks the mechanism of the claim (a removed guard, a relaxed memory order). A mutant that only corrupts the input of the checker proves only the checker.
- A guard that compares measured quantities gets a mutant of an operand that widens or narrows what it measures, for example the whole bounds in place of the visible rect; its fixture makes each region differ in each dimension. A test that sets the other condition of a compound guard cannot reach this one.
- Run each mutant under the exact conditions of the claim. Turn on a condition that is off (a compiler feature) with another old/new pair of the mutant (`--in=<file> <old> <new>`), so mutate.py restores it.

## Run the pass

- Write each mutant as one `mutant <file> <old> <new> <log> <build> <test>` line of a batch file. Put `--switch expr` (whole expressions) or `--switch stmt` (whole statements) first, with each old text once in its file; these share one build. A declaration, a real-time callback, and an app or screen test get no `--switch`. Run `.claude/skills/deliver/scripts/mutation-pass.sh <worktree> <batch file>` once, with `run_in_background` and a Bash `timeout` of 7200000: it holds the build lock once for the batch.
- The build command is `scripts/with-lock.sh swift build --build-tests`, with no pipe. The test command is `scripts/test-filter.sh --skip-build --exact <name>`.
- A mutant with two edits (a guard mutant and the fault that trips it) is one call with two old/new pairs. Put `--in=<file>` before the pairs of a second file. Never apply an edit with a script in the build or test command.
- Do not nest mutate.py in its test command. After `NO TESTS` or `BUILD FAILED`, correct the filter or the mutant and run it again.
- Warnings are errors, so mutate the source of a value, not the place that uses it.
- Pass the assertion message of the killing test with `--expect <text>`, not a test name. A guard and its refusal message read the limit from one variable.
- Pass `--timeout <seconds>`, a few times the green test time: a hang gives `killed (hang)`, with `--expect` only when the text came before the kill. A crash or a throw before the assert gives `WRONG FAILURE`: the mutant keeps the shape of the data that later code reads, and the test reads its input with `try?`.
- mutate.py restores only the source file, from a hash-checked copy, never from git. So the build command first deletes or builds again each shared output that its test reads, also for a survivor that runs again. A `BUILD FAILED` right after another mutant can come from its outputs.
- A test command that acts on shared state (Mission Control, HID events, a probe) runs only when no other agent uses the screen. A test command that writes output (a session, a capture) gets a new folder on each run (`d=$(mktemp -d)` in single quotes): the old state of an earlier run can fail the command before it reaches the guard.
- Save each log under `<run>/controls/`, and cite it in a phase 7 `decisions.tsv` row whose decision starts with `mutation pass`: the pass row. `scripts/land.sh` refuses a risk run with no pass row.

## Read each survivor

- The lead reads each survivor, also run with `DIRIGIBLE_SLOW_TESTS=1`, and logs it with the result `survived`; when only the slow run kills it, with the result `survived the fast suite`. A second agent checks each claim that a mutant is equivalent.
- Equivalent: no caller can reach the mutated behavior. Log the caller reason in `decisions.tsv`, and stop. A probe that measured one effect of the mutant is not a caller reason.
- Misaimed: the mutant does not reach the planned path. Fix the mutant once, and log the misaimed one.
- Each other survivor is the red step of a new test. Write the test; the killed log is its proof.
- When only the test process has the mechanism that hides the mutant (Return reaches a list action there that a real Return does not), retire the mutant with that reason in `decisions.tsv`, and prove the path on the built app. Never change a product mechanism only so that a mutant can kill it.
