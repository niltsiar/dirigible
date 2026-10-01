# Mutation controls

Deliver Phase 2 says which guards get controls. The docstring of `.claude/skills/deliver/scripts/mutate.py` gives each flag and each result line.

## Plan the controls

- A plan that says "no control is possible" or "a reviewer reads it" needs a logged probe first. Look for an input that only the path with no guard refuses, for example a bogus environment value that a pin must ignore.
- The slice commits that test. A control that exists only as prose in `analysis.md` first runs in Phase 7, too late to change the slice.
- For each guard condition, run two mutations: one that accepts too much and one that refuses too much.
- A guard that compares measured quantities (an area, a count, a duration) also gets one mutation per operand that widens or narrows what it measures, for example the whole bounds in place of the visible rect. Its fixture makes each region differ in each dimension.
- Each test named for the criterion must fail under at least one of them.
- A test that sets the other condition of a compound guard cannot reach this one.
- A test that asserts "X happens during Y" also asserts that Y goes on.
- The control breaks the mechanism of the claim (a mutation that relaxes a memory order or removes a guard). A control that only corrupts the input of the checker proves only the checker.
- Run the control under the exact conditions of the claim. Turn on a condition that is off (a compiler feature) with a temporary change that you revert. A control under other conditions proves only itself.

## Run a control

- Run a source mutation before the slice commit with `.claude/skills/deliver/scripts/mutate.py <file> <old> <new> <log> <build> <test>`. It saves the raw output to the log, restores the file, and checks its hash.
- A control with two edits (a guard mutant and the fault that trips it) is one call with two old/new pairs. Put `--in=<file>` before the pairs of a second file. Never apply an edit with a script in the build or test command, which a replay cannot see.
- Do not nest mutate.py in its test command: the outer result line then gives the verdict of the inner call. After `NO TESTS` (the filter matched no test) or `BUILD FAILED` (proves nothing), correct the filter or the mutant and run it again.
- Warnings are errors, so mutate the source of a value, not the place that uses it: a mutant that leaves a binding unused does not build.
- Pass the assertion message of the killing test with `--expect <text>`, not a test name: the progress lines name every test in the filter.
- A guard and its refusal message read the limit from one variable, else `--expect` misses a mutant of the limit and a user reads a wrong limit.
- Pass `--timeout <seconds>`, a few times the green test time. A hang then gives `killed (hang)`; with `--expect`, only when the text came before the kill.
- A crash or a thrown error before the assert gives `WRONG FAILURE`, so the mutant keeps the type and shape of the data that later code reads.
- A test that a control breaks reads its input with `try?` or `FileManager.contents(atPath:)`, and runs a tool that exits non-zero on the broken input through `try?`, so the assert message comes.
- mutate.py restores only the source file. A tool can crash on the build outputs of a mutant: `hdiutil convert` gave "Segmentation fault: 11" on an old output file. So the build command first deletes or builds again each shared output that its test reads. A `BUILD FAILED` or a tool crash right after another control can come from the outputs of that control.
- Mark a control whose test command acts on shared state (Mission Control, HID events, a probe) with `--side-effects`. Decide it from what the command does under the mutant: a removed guard can let a test reach a build, the app, or HID events.
- A test command that writes output (a session, a capture) gets a new folder on each run, for example `<run>/x-$(date +%s)`: a replay into the old folder fails before it reaches the guard.
- Save the log under `<run>/controls/`, and cite its path in a `decisions.tsv` row of phase 2 or 4. Phase 7 then replays the control from its log. With `risk: yes`, `scripts/land.sh` refuses a run with no such row, unless its third argument names the row that says why no control applies.

## When no test fails

- Another mechanism can hide the planned mutation. If no test fails, do not pass the item to the code gate. Write a test that reaches the guard past the other mechanism, or remove the guard.
- When the other mechanism exists only in the test process (Return reaches a list action there that a real Return does not), retire the control with that reason in `decisions.tsv` and prove the path on the built app. Never change a product mechanism only so that a control can kill it: a row gesture added for a control broke single-click select.
- A mutation that does not reproduce the failure is a finding: record it, then find the mutation that does.
- When no caller can reach the mutated behavior, the mutant is equivalent. Record the caller reason in `decisions.tsv`, and stop. A probe that measured one effect of the mutant is not a caller reason.
- A surviving mutant that moves framework setup (a value set before or after an object takes ownership) stays on the replay list. Check it first when a check of the built app finds a defect.
- Run a surviving control again with `DIRIGIBLE_SLOW_TESTS=1`. If only that run kills it, record "guarded only by slow tests" in `decisions.tsv`.
- Retire a control only in a `decisions.tsv` row that names its successor for the same direction, or says why that direction no longer exists.

## Replay once in Phase 7

- Replay each killed control once, on the tree that lands, with `mutate.py --timeout <seconds> --replay <old log> <new log>`. Replay all of them: a change in a caller in a third file can make the mutated code unreachable. After a return from Phase 7 to Phase 4, replay only the logs that `.claude/skills/deliver/scripts/replay-list.sh <controls folder> <commit of the full replay>` prints.
- A replay runs the logged test command again, with every side effect. After the last replay, build the product again from the clean tree.
