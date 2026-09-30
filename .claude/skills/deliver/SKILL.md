---
name: deliver
description: "End-to-end flow for any feature, requirement, or bug in this repo: analyze, plan, review the plan, implement test-first in atomic commits, review the code, verify, reflect, and land, with a run ledger in .scratchpads/. Use for /deliver, 'implement R3', 'build the next feature', 'plan and implement', or any autonomous run."
---

# Deliver

One run takes one goal from request to a merged pull request on `main`. A goal is a requirement (`R3`), a slice of one, or a bug. Every step writes to the run ledger, so a human or the next agent can see what happened and why.

Open a todo list with the phases below before you start. Do not skip a phase. A phase can be short when the goal is small, but it must leave its artifact.

## Autonomy rules

- Do not block on the human for reversible work. Choose a sensible default, record it in `decisions.tsv`, and continue. The human corrects it later.
- Stop and ask only for irreversible or outward-facing actions: deleting user data, rewriting `main` history, publishing outside this repo. Pushing a run branch, opening its pull request, and merging it are part of the flow and need no question.
- When a check needs hardware you cannot drive (a second audio interface, a permission prompt), write the manual check in `run.md` under "Manual checks" and continue with the closest automated check. A manual check makes a criterion weaker, so probe the limit first and log the probe in `decisions.tsv`. For mouse and key input, use `scripts/hid.swift` (CGEvents posted at the HID tap) against the built app: with Accessibility trust they do a real drag, a key press with the button held, a release outside the window, and Cmd-Z.
- Keep the main context small. Send bulk reading to subagents. Keep their conclusions, not their raw output.
- When a subagent does a phase, its prompt names each run file it writes (`analysis.md`, `plan.md`, `design.md`) as a required ledger file of this flow. The Write tool can still refuse a report-like file in a subagent. Then the subagent writes the run file at once with a Bash heredoc. It does not retry the Write tool, and it does not return the file only as text.
- A subagent runs a repeat loop (a flake check, a set of mutations) in the foreground, with a Bash timeout of 10 min or less per call. Split a longer loop into more calls. A background loop makes the subagent wait, and the caller gets many interim notifications.
- Send every research request, from a phase or from the user in the middle of a run, through the **research** skill. Its output goes to `docs/research/`, where `make check-docs` checks it. While a monitored loop or a bench runs, the prompt of each subagent says so. A ban on `swift` in the prompt alone did not stop a research subagent, because the research skill told it to probe.

## Phase 0: Open the run

1. Read `.scratchpads/learnings.md`, `.scratchpads/backlog.md`, and `.scratchpads/ledger.md`.
2. Look for unfinished work: `git status --porcelain`, `git branch`, and any run with status `open` in the ledger. If a run is open, resume it: switch to its branch, read its `run.md` and `decisions.tsv`, and continue at the first unchecked phase. Do not switch to `main` with uncommitted changes.
3. For a new goal, run `.claude/skills/deliver/scripts/new-run.sh <slug>`. It creates `.scratchpads/runs/<date>-<slug>/` with `run.md` and `decisions.tsv`, and adds a line to `.scratchpads/ledger.md`. For the slug of an open run, it returns that folder. It never reopens a done run. Add every `decisions.tsv` row with `.claude/skills/deliver/scripts/log-decision.sh <run folder> <phase> <decision> <why> <evidence> <result>`. The script writes `ts` from the clock. Do not type a row by hand, and tell each subagent that writes rows to use the script.
4. For a new goal, make sure `main` is green: `git switch main && make check`. If it is red, fixing it is the goal of this run.
5. Create the branch now, before any file changes: `git switch -c <type>/<slug>`, for example `feat/multitrack-capture`. Write it in `run.md`. Every commit of the run, including decision records and reflect learnings, goes on this branch.

## Phase 1: Analyze

Write `analysis.md` in the run folder:

- The requirement IDs from `docs/requirements/brief.md` that this run covers.
- How Hindenburg PRO behaves for this feature. Research it with the **research** skill. Cite the sources.
- Acceptance criteria as falsifiable statements. Each criterion names how a test or command proves it. Example: "A 10 s recording from two devices gives two WAV files of 10 s ± 20 ms and one session XML with two `<track>` elements."
- Assumptions and open questions. Answer each question with a default and record it in `decisions.tsv`. When a default departs from the researched reference behavior because of an assumed platform limit, probe that limit first. An unprobed limit is a guess.
- What is out of scope for this run. Put the rest in `.scratchpads/backlog.md`.

## Phase 2: Plan

Write `plan.md`:

- Split the goal into vertical slices. Each slice ends in a state you can check: a test that passes and a commit. Put the riskiest unknown first. Types that reference each other go in one slice.
- For each slice: the test you write first, the modules you touch, and the commit message you expect. When the slice covers an acceptance criterion, also name the test that asserts its negative control. A plan that says "no control is possible" or "a reviewer reads it" needs a logged probe first. Look for an input that only the path with no guard refuses, for example a bogus value of an environment variable that a pin must ignore. The slice commits that test. A control that exists only as prose in `analysis.md` is first run in Phase 7, too late to change the slice. When the control is a source mutation and not a committed test, run it before the slice commit with `.claude/skills/deliver/scripts/mutate.py <file> <old> <new> <log> <build> <test>`. It saves the raw output to the log, restores the file, and checks its hash. A control with two edits, for example a guard mutant and the fault that trips it, is one call with two old/new pairs. For an edit in a second file, put `--in=<file>` before its pairs; never apply it with a script in the build or test command, which a replay cannot see. A `NO TESTS` result means the filter matched no test: correct the filter and run it again. Do not nest mutate.py in its test command: the outer result line then gives the verdict of the inner call. A `BUILD FAILED` result proves nothing: correct the mutant and run it again. mutate.py restores only the source file. The build outputs of a mutant stay (a product file, an app with a mutated `Info.plist`), and a tool can crash on them: `hdiutil convert` gave "Segmentation fault: 11" on an old output file. So the build command of a control first deletes or builds again each shared output that its test reads, and a replay gets the same clean state. A `BUILD FAILED` or a tool crash right after another control can come from the outputs of that control. Warnings are errors, so change the source of a value (for example the expression that makes it), not the place that uses it: a mutant that leaves a binding unused does not build. Pass the assertion message of the killing test with `--expect <text>`, not a test name or an argument label: the script ignores the progress lines (a test started or passed), and those lines name every test in the filter. A guard and its refusal message read the limit from one variable: a message with its own copy of the limit stays the same under a mutant of the limit, so `--expect` misses it, and a user reads a wrong limit. Pass `--timeout <seconds>` on every control, a few times the green test time: the log header keeps it, and a replay with no limit exits 2. A mutant that makes the code hang (a display loop, a lock that never opens) is a kill, but no wait limit inside the test can end it: the script kills the test at the limit and reports `killed (hang)`. With `--expect`, a hang counts only when the text came before the kill; a failure report that hangs gives `WRONG FAILURE`. A mutant that crashes (an index out of range) also fails the test; the script then gives `WRONG FAILURE`, and the mutant must keep the type and shape of the data that later code reads. A thrown error before the assert gives `WRONG FAILURE` too. A test that a control breaks reads its input with `try?` or `FileManager.contents(atPath:)`, and it runs a tool that exits non-zero on the broken input through `try?`, so the assert message comes. Cite the log path in the `decisions.tsv` row. Phase 7 then replays the control from its log. For each guard condition, run two mutations: one that accepts too much and one that refuses too much. A guard that compares measured quantities (an area, a count, a duration) also gets one mutation per operand that widens or narrows what it measures, for example the whole bounds or the visible rect in place of the part in view. Its fixture makes each of those regions differ in each dimension. Each test named for the criterion must fail under at least one of them. A test that sets the other condition of a compound guard cannot reach this one. A test that asserts "X happens during Y" also asserts that Y goes on. Another mechanism can hide the planned mutation. If no test fails, do not pass the item to the code gate. Write a test that reaches the guard past the other mechanism, or remove the guard.
- A performance criterion names its build configuration (debug or optimized) and its size, for example the window size in pixels. Its test asserts the real budget under those conditions. Name the make target that runs the test, for example `make bench FILTER=<test>` for an optimized budget. A timing at other conditions (a debug budget, a smaller window) is a proxy and cannot close the criterion. A criterion that no committed command runs is a manual check. The criterion also names each input path that reaches the costly code (for example each gesture that redraws), the worst-case fixture shapes (many items per lane, one item wider than the view, a change at the end), and the real input rate. A pointer gives at most one event per display frame, so the benchmark sends one event per frame: events sent back to back measure the frame throttle, not the event. A path that the criterion does not name is not covered by its budget. A budget cannot see a regression that stays under it. For a known slow cause (a view body that runs again, a full render), also assert a count that does not use time, for example a DEBUG counter of body runs, with a control that puts the cause back. A test that reads a DEBUG-only counter is in `#if DEBUG` too: `make bench` builds the tests with no DEBUG. In a bench that times two events in one frame (a real event, then a tick), each event must change the output: assert it for each event after the clock stops, as a Bool, and run a control that sends the same input twice. A per-frame count passes when either event does the work.
- A rule that classifies a loop run or names the holder of a sample (a trigger that picks a plan branch, a rule that says whether test code or product code holds a thread) is a script in the run folder, not prose. Write it before the data, and run it on the green runs of the baseline loop before the plan gate. A rule that fires on green runs decides nothing: a trigger "the failed run has samples that name a CLI test" fired on every run, green or red, because each sample named a CLI test. A rule that changes after the data is a criterion change (Phase 4 step 4).
- When a change adds a new way to move or resize something (a drag, an inset, a zoom), list each existing redraw or cache guard that reads that geometry, and give each one a test where the new input changes the drawn output while the key of the guard stays the same. The fixtures of these tests and the on-screen checks include the default state: fit zoom, origin 0, a document shorter than the view. A long, scrolled fixture can hide a stale drawing, because AppKit copies the pixels at a scroll.
- If a slice sets a one-way decision (a file format, a module boundary, a threading model, a new dependency), run the **architect** skill for it and write a decision record in `docs/decisions/`.
- For each item of the plan, grep `docs/decisions/` and `AGENTS.md` for its subject. When the item changes or removes a rule, also grep the exact phrase of the rule and its key terms in `docs/`, `Sources/` (comments too), and `Tests/`. A test that asserts the old rule is a copy of it: list it in `plan.md` as a planned change of its expected value, with the old and the new value. Quote each rule that you find, do not paraphrase it, and say if the plan keeps it or changes it. A change is a one-way decision that amends that record. Check each fix option against the probes that the record gives: a probe can already refute an option.

## Phase 3: Plan gate

Run the **interrogate** skill with target `plan`. It runs the `review-panel` workflow (premortem, devil's advocate, architecture) and gives a judged verdict.

Keep `Sources/` and `Tests/` unchanged until the gate closes. While the panel runs, prototype in the run folder only.

- Change the plan for every "Act on" item. Record each change in `decisions.tsv`. When an item says how to detect a failure of an external tool (an error line, an exit status), probe each failure mode first: the exit status, the product files, and the message text in each output format. Guard on the exit status and the product files, not on message text: `actool` exits 0 with no files and only a warning for a broken `.icon`. When a fix changes a fact (a scope rule, a release, a reason), grep its ID or term across `docs/` and the run files, and fix each copy in the same change.
- If the verdict had a critical item, run the gate again. At most two rounds. Round 2 is the convergence round: it checks only the round-1 fixes (see the **interrogate** skill). After its fixes and one fix check, record any open risk in `run.md` and continue.

## Phase 4: Implement

1. For each slice, follow the **tdd** skill: failing test, smallest change, `make check`, commit. Run the check and the commit as one command, `make check > <log> 2>&1 && git commit ...`, so a red check stops the commit; the guardrail hook refuses any other join. Commit the slice before you write a file of the next slice. After heavy work (disk images, benches, many builds), run `uptime` and wait until the load average is back to its normal value before a `make check`: its timing tests fail under load.
2. One commit is one logical change. Use Conventional Commits (see `AGENTS.md`). Never commit a red `make check`.
3. After each slice, add a row to `decisions.tsv` and tick the slice in `run.md`. The row gives the `make test` time on `main` and on the branch. When the branch time is two times the `main` time or more, stop and treat the cost as a plan change (step 4). Many small "kept" steps must not add up to a slow suite that nobody decided on.
4. If the plan proves wrong, stop, update `plan.md`, and record why. Do not bolt workarounds onto a wrong plan. A plan change that makes a criterion weaker (a looser budget, a smaller size, a check moved to a later phase) because a tool "cannot" do something needs a probe first. Try to meet the original conditions, and log the probe in `decisions.tsv`. An untried tool limit is a guess, as in Phase 1. A plan change that changes a criterion also edits its text in `analysis.md` in the same step and cites the `decisions.tsv` row. Phase 7 then verifies the text that applies, not "as amended".
5. If a slice changes what a user sees or does, update `docs/guide.md` in the same slice. The code gate then reviews the guide text with the code.

## Phase 5: Clean up

Run the **deslop** skill on the branch. Run `make check`. Commit the cleanup on its own.

## Phase 6: Code gate

Run the **interrogate** skill with target `diff`. It runs the `review-panel` workflow (premortem, devil's advocate, architecture, code quality).

- Fix every "Act on" item with its own commit. A bug fix gets a regression test first.
- Put "Consider" items you do not do now in `.scratchpads/backlog.md` with the reason.
- When a user decision reverts an earlier fix, the symptom that the fix addressed can come back. Write that symptom in the manual checks of `run.md` and in the review section of `pr.md`.
- If the verdict had a critical item, run the gate again after the fixes. At most three rounds. Round 2 follows up on round 1. Round 3 is the convergence round: it checks only the earlier fixes. After its fixes and one fix check (see the **interrogate** skill), the gate is closed. Its out-of-scope findings go to the backlog.

## Phase 7: Verify

Run the **verify-this** skill for each acceptance criterion from Phase 1 against the real artifact: the built app, the real files, measured levels. Record each verdict (`VERIFIED`, `NOT VERIFIED`, `INCONCLUSIVE`) in `run.md`. A `NOT VERIFIED` criterion sends you back to Phase 4. First stop the running control replays (`pkill -INT -f mutate.py` restores the file): the fix changes the code that they test. Replay all controls once, on the tree that lands. If the window looks different, make the screenshots again (`docs/guide.md`, For contributors).

## Phase 8: Reflect

Run the **reflect** skill on the branch. It turns durable learnings into commits on skills, agents, `AGENTS.md`, or checks. Run `make check` after its commits. When the run had no friction, reflect records "no learnings" in `decisions.tsv` and makes no commit.

## Phase 9: Land through a pull request

1. `git fetch origin && git rebase origin/main`, then `make check`. Rebase before the first push, so the branch never needs a force push. When the branch changes `Sources/`, also run the slow tests: `git diff --quiet origin/main...HEAD -- Sources || make test-slow`. `make check` does not run them, and slow tests are in every test target. After `make check`, when the branch changes the app bundle or the DMG, run the DMG check: `git diff --quiet origin/main...HEAD -- scripts/bundle.sh scripts/dmg.sh scripts/test-dmg.sh scripts/icon.sh Support Makefile Tests/DirigibleTests/AppBundleTests.swift Tests/DirigibleTests/DiskImageTests.swift || make test-dmg`. `make check` does not run it, because it takes 22 to 56 s and each mount loads Finder. Also run `make bench FILTER=<test>` for each optimized budget that a criterion of the run names.
2. `git push -u origin <branch>`.
3. Write the PR body with the **pr** skill to `<run>/pr.md`. Then `gh pr create --base main --head <branch> --title "<plain title, see the pr skill>" --body-file <run>/pr.md`.
4. Make sure `main` did not move after step 1: `git fetch origin && git merge-base --is-ancestor origin/main HEAD`. If this fails, `make check` did not test the result of the merge. Go back to step 1 on a fresh branch. Then `gh pr merge <branch> --rebase --delete-branch`. Rebase merge keeps each atomic commit on `main` and keeps history linear.
5. `git switch main && git pull --ff-only origin main && git fetch --prune origin`. `gh pr merge --delete-branch` also deletes the local branch. A rebase merge gives the commits new hashes, so `git branch -d` refuses a leftover branch. Leave it and record it in `run.md`.
6. If `main` moved after the push and the merge fails, stop the land step. Record the conflict in `run.md`, and resolve it with the **resolving-merge-conflicts** skill on a fresh branch. Never force-push.
7. In `run.md`, set the status to `done`, and write a summary: what landed (PR and commit range), what is verified, manual checks for the human, and open risks. The summary and the PR body also list each `decisions.tsv` default that waits for the user (result "open for the user"), with the later run that must stop for it.
8. Write the PR URL in `run.md` and in the run line of `.scratchpads/ledger.md`.

## Long autonomous runs

To work through several goals, repeat the phases for the next goal from `.scratchpads/backlog.md` or the order agreed in the first planning run. Close each run before you open the next one.

The `AGENTS.md` in the context is the copy from the start of the session, and subagents get the same copy. Reflect commits change the file on disk, not that copy. At the start of each run, read `AGENTS.md` from disk. Each subagent prompt says that the file on disk wins over the copy in its context.

Before the first run of an unattended loop, check that Phase 9 can run without a prompt: `git ls-remote origin` and `gh auth status`. If one fails, stack each run branch on the previous one, record it in `run.md`, and land them when the human is back. Use only the access these two commands already have; leave credential stores closed. Every run lands on `main` green through its own pull request, so the human can stop the loop at any time and find a working app.

## Write everything in STE

Plans, ledger rows, review verdicts, and commit messages follow the **technical-writing** and **unslop** skills: short sentences, active voice, one idea per sentence, one word for one thing.
