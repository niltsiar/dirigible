---
name: deliver
description: "Deliver one goal end to end: analyze, plan, gate, implement test-first, review, verify, reflect, and land. Use for /deliver, 'implement R3', 'build the next feature', or any autonomous run."
---

# Deliver

One run takes one goal (a requirement, a slice of one, or a bug) to a merged pull request on `main`. Every step writes to the run ledger for the next agent. Open a todo list with the phases. Do not skip a phase; a short phase still leaves its artifact.

## Autonomy rules

- For reversible work, choose a default, log it in `decisions.tsv`, and continue. The human corrects it later.
- Ask only before irreversible or outward-facing actions: deleting user data, rewriting `main` history, publishing outside this repo. `scripts/land.sh` (the push and the merge) needs no question.
- When a check needs hardware you cannot drive, write a manual check in `run.md` and do the closest automated check.
- Subagents do bulk reading and return conclusions. A subagent prompt names each run file it writes (`analysis.md`, `plan.md`, `design.md`) as a required ledger file. Write run files with the Write tool; if it refuses, edit an empty file that the lead made, or use a `.tsv` or `.txt` name. Never return a run file only as text.
- A subagent runs a repeat loop in the foreground, 10 min or less per Bash call; split a longer loop into more calls. A background loop floods the caller with notifications.
- Send every research request through the **research** skill. While a loop or a bench runs, each subagent prompt says so: a `swift` ban alone is not enough.
- Each backlog write names its section of `.scratchpads/backlog.md`: `## Next` for a user request or a next-run item, `## Later` for a "Consider" item and all other deferred work.

## Phase 0: Open the run

1. Read `.scratchpads/ledger.md`, the `## Next` section of the backlog, and the last `run.md`. The **reflect** skill reads `learnings.md`.
2. Find unfinished work: `git status --porcelain`, `git branch`, runs with status `open`. Resume an open run on its branch: read its `run.md` and `decisions.tsv`, and continue at the first unchecked phase. Do not switch to `main` with uncommitted changes.
3. For a new goal, run `.claude/skills/deliver/scripts/new-run.sh <slug>`.
4. Run `make check` on `main` only when `main` has commits that no run landed. If it is red, the fix is the goal.
5. Before any file change, create the branch `<type>/<slug>` and write it in `run.md`. Every commit of the run goes on it.

## Phase 1: Analyze

Write `analysis.md`:

- The requirement IDs of `docs/requirements/brief.md`, and how Hindenburg PRO behaves, with sources.
- Falsifiable acceptance criteria, each with the test or command that proves it. Each clause gets its own assert or a named manual check. A trigger (a command, a key) gets one case per start state: the window closed or shown, the focus in each control. Example: "A 10 s recording from two devices gives two WAV files of 10 s ± 20 ms."
- Open questions, each answered with a logged default.
- An untried limit is a guess. Probe a platform or tool limit before it moves a default from the reference behavior, turns a check manual, or weakens a criterion. Try to meet the original conditions, and log the probe.
- What is out of scope, in the backlog.

## Phase 2: Plan

Write `plan.md`:

- Vertical slices, each ending in a passing test and a commit. The riskiest unknown goes first. Types that reference each other share a slice.
- For each slice: the first test, the modules, the commit message, and `scripts/check-changed.sh --paths` on its paths. A slice that covers a criterion names the test of its negative control.
- When the `risk:` line says `yes`, or a plan says that no control is possible, read `references/mutation-controls.md`.
- When a criterion sets a time budget, adds a way to move or resize something, or a rule classifies loop runs, read `references/performance-criteria.md`.
- A one-way decision (a file format, a module boundary, a threading model, a dependency) gets the **architect** skill and a record in `docs/decisions/`.
- Grep `docs/decisions/` and `AGENTS.md` for each item. When an item changes a rule or a fact, grep its exact phrase and key terms in `docs/`, `Sources/` (comments too), `Tests/`, and the run files, and fix each copy in the same change. A test of the old rule is a copy: plan its old and new value. Quote each rule found and say if the plan keeps or changes it. A change amends that record. A probe in the record can refute a fix option.

### Checks by change class

`scripts/check-changed.sh` prints `classes:`, `targets:`, and `risk:` (decision 0028). `make check-changed` runs the targets. A mixed change gets the union of its rows and the larger round count.

| Class | Review panel rounds (Step 3 of the **interrogate** skill picks the lenses) |
|---|---|
| docs | 1 round and a fix check |
| tooling, tests, bundle, build | 1 round |
| sources | plan gate 1 round; code gate 1 round and a fix check |
| sources-risk | plan gate 2 rounds; code gate 3 rounds |

- A sources change gets a screenshot or AX check per visible criterion. A tooling control is a failing case in its `.test.sh`.
- A 1-round gate calls the workflow with `maxRounds: 2`; round 2 runs only on a critical item.
- With `risk: yes`, each guard in a risk path gets two mutation controls, replayed once in Phase 7. With `risk: no`, the failing-before test is the control, with no replay. Decision 0028 says when a plan raises a guard to risk.

## Phase 3: Plan gate

Run the **interrogate** skill with target `plan` (premortem, devil's advocate, architecture). Keep `Sources/` and `Tests/` unchanged until the gate closes; prototype in the run folder only.

- Change the plan for each "Act on" item and log it. Grep each fact that a fix changes, as in Phase 2.
- Before you detect a failure of an external tool, probe its exit status, product files, and messages. Guard on the exit status and the product files, not on message text.
- A critical item gets another round, up to the class table. Round 2 follows up on round 1. The last round checks only the earlier fixes. After them and one fix check, the gate is closed: record open risks in `run.md`.

## Phase 4: Implement

1. Each slice follows the **tdd** skill. Join the check and the commit, so a red check stops the commit: `make check-changed > <log> 2>&1 && git commit ...`. Commit the slice before a file of the next slice. After heavy work, wait until `uptime` shows a normal load before a check that runs tests: timing tests fail under load.
2. Use Conventional Commits (see `AGENTS.md`).
3. After each slice, log a row and tick `run.md`. Time `make test` on `main` once per run, and log the branch time. At two times the `main` time, stop and treat the cost as a plan change.
4. If the plan proves wrong, stop, update `plan.md`, and log why. A changed criterion gets its new text in `analysis.md` in the same step, citing the row, so Phase 7 verifies that text.
5. A slice that changes what a user sees or does updates `docs/guide.md`.

## Phase 5: Clean up

Run the **deslop** skill. Commit the cleanup on its own.

## Phase 6: Code gate

Before the gate, run `scripts/check-changed.sh origin/main`. When its classes or its risk are higher than in the plan, go back to Phase 2 for the controls and the rounds, and log a row.

Run the **interrogate** skill with target `diff` and the rounds of the class table.

- Fix each "Act on" item in its own commit, a bug fix with its regression test.
- Put each "Consider" item that you skip in `## Later`, with the reason.
- When a user decision reverts a fix, write its symptom in the manual checks and in `pr.md`.
- Run the rounds as in Phase 3. Out-of-scope findings go to `## Later`.

## Phase 7: Verify

Run the **verify-this** skill for each criterion against the real artifact (the built app, the real files, measured levels), and record each verdict in `run.md`. `NOT VERIFIED` sends you back to Phase 4; first stop running replays (`pkill -INT -f mutate.py` restores the file). With `risk: yes`, when you replay the controls once on the tree that lands, read `references/mutation-controls.md`. If the window changed, make the screenshots again (`docs/guide.md`, For contributors).

## Phase 8: Reflect

Run the **reflect** skill on the branch. With no friction, it logs "no learnings" and makes no commit. Then review the `## Later` headings, and move each item that this run made due to `## Next`.

## Phase 9: Land through a pull request

1. Run `make bench FILTER=<test>` for each optimized budget of a criterion.
2. Write `<run>/pr.md` with the **pr** skill. Then run `scripts/land.sh "<plain title>" <run>/pr.md`. It stops at the first failure, and prints the PR URL and the commit range.
3. If the merge fails, record the conflict in `run.md` and use the **resolving-merge-conflicts** skill on a fresh branch. Leave a leftover local branch after the merge, and record it in `run.md`.
4. Set `run.md` to `done` with a summary: what landed (PR, commit range), what is verified, manual checks, and open risks. It and the PR body list each default "open for the user", with the run that must stop for it. Write the PR URL in `run.md` and the ledger.

## Long autonomous runs

When one session runs several goals or an unattended loop, read `references/long-runs.md` before the first run.
