---
name: deliver
description: "Deliver one goal end to end: analyze, plan, gate, implement test-first, review, verify, reflect, and land. Use for /deliver, 'implement R3', 'build the next feature', or any autonomous run."
---

# Deliver

One run takes one goal (a requirement, a slice of one, or a bug) to a merged pull request on `main`. Every step writes to the run ledger for the next agent. Open a todo list with the phases. Do not skip a phase; a short phase still leaves its artifact.

## Autonomy rules

- For reversible work (AGENTS.md, Git), choose a default, log it in `decisions.tsv`, and continue. Its row result starts with `default`; its why and the PR body name what reverses it (`Reverse:`). `scripts/land.sh` needs no question. A privacy prompt of the verify copy: `driving-the-app.md`.
- A row result starts with its token when one applies: `failed` or `fail` (a check failed, not a planned red), `flake`, `survived` (a mutant), `NOT VERIFIED`, or `missed unknown`. A token wins over `default`; then start the decision with `default`. A changed criterion starts the decision with `criterion change` (`log-decision.sh` checks it).
- When a check needs hardware you cannot drive, write a manual check in `run.md` and do the closest automated check.
- Subagents do bulk reading and return conclusions. A subagent prompt names each run file it writes (`analysis.md`, `plan.md`, `design.md`) as a required ledger file. Write run files with the Write tool (AGENTS.md, Git). If the tool refuses, write `<name>.txt`, then `mv` it to `<name>.md`. Never return a run file only as text.
- A subagent runs a repeat loop in the foreground, 10 min or less per Bash call; split a longer loop into more calls. A background loop floods the caller with notifications.
- Send every research request through the **research** skill. While a loop or a bench runs, each subagent prompt says so: a `swift` ban alone is not enough.
- Each backlog write names its section of `.scratchpads/backlog.md`: `## Next` for a user request or a next-run item, `## Later` for a "Consider" item and all other deferred work.
- Before you fake or detect a failure of an external tool, probe it (exit status, stderr, files). Record each result in its `## Unknowns` row. The fake copies each result. Guard on the status and files. For a status with several causes, make your call print a marker text, and guard on that.

## Phase 0: Open the run

1. Read `.scratchpads/ledger.md`, the `## Next` section of the backlog, and the last `run.md`. The **reflect** skill reads `learnings.md`.
2. Find unfinished work: `git status --porcelain`, `git branch`, runs with status `open`. Resume an open run on its branch: read its `run.md` and `decisions.tsv`, and continue at the first unchecked phase. Do not switch to `main` with uncommitted changes.
3. For a new goal, run `.claude/skills/deliver/scripts/new-run.sh <slug>`.
4. Run `make check` on `main` only when `main` has commits that no run landed. If it is red, the fix is the goal.
5. Before any file change, create the branch `<type>/<slug>` and write it in `run.md`. Every commit of the run goes on it.

## Phase 1: Analyze

Write `analysis.md`:

- The requirement IDs of `docs/requirements/brief.md`, and how Hindenburg PRO behaves, with sources.
- Falsifiable acceptance criteria, each with its proving test or command. Each clause gets an assert or a named manual check. A trigger (a command, a key) gets one case per start state: the window closed or shown, the focus in each control. For each threshold, write one passing value and one failing value.
- The `## Unknowns` table (columns: `scripts/check-plan.sh`). The resolver is `code`, `probe`, `research`, `prototype`, `default`, or `user` (only for an irreversible step or a product choice with no reference behavior, and the run continues on a logged default). A question that is not sharp yet gets `split` and child rows. Resolve first the rows whose parent has an answer. A look-and-feel unknown gets `prototype` before the plan gate: a screenshot of a throwaway build in the probe sandbox, judged against the reference app.
- An untried limit is a guess. Probe a platform or tool limit before it moves a default from the reference behavior, turns a check manual, or weakens a criterion. Try to meet the original conditions (a probe for a test runs in the test runner), and log the probe.
- What is out of scope, in the backlog.

## Phase 2: Plan

Write `plan.md`:

- Vertical slices, each ending in a passing test and a commit. The riskiest unknown goes first. Types that reference each other share a slice.
- For each slice (a `###` heading): the first test, the modules, the commit message, and a `- Check:` line with `scripts/check-changed.sh --paths` on its paths. A slice that covers a criterion names the test of its negative control.
- An `Agents:` line: the agent groups (small adjacent slices of one module share an agent), which groups run at the same time (no shared file or build output), and why the others wait.
- When the `risk:` line says `yes`, or a plan says that no control is possible, read `references/mutation-controls.md`.
- When a criterion sets a time budget or fixes a missed budget, adds a way to move or resize something, or a rule classifies loop runs, read `references/performance-criteria.md`.
- A bug goal proves its fix with its red repro log (tdd step 7). A refactor or a file split pins the behavior with a test before code moves, and reverts a move that deletes no branch, copy, or layer.
- A one-way decision (a file format, a module boundary, a threading model, a dependency) gets the **architect** skill and a record in `docs/decisions/`.
- Grep `docs/decisions/` and `AGENTS.md` for each item. When an item changes a rule or a fact, grep its exact phrase and key terms in `docs/`, `Sources/` (comments too), `Tests/`, and the run files, and fix each copy in the same change. A test of the old rule is a copy: plan its old and new value. Quote each rule found and say if the plan keeps or changes it. A change amends that record. A probe in the record can refute a fix option.

### Checks by change class

`scripts/check-changed.sh` prints `classes:`, `targets:`, and `risk:` (decision 0028). `make check-changed` runs the targets.

| Run | Plan gate and code gate |
|---|---|
| Small (`risk: no`) | One subagent runs Phases 1-2 and 4 and returns the plan path, the commit range, and the gate inputs. The lead runs the gates. Each gate: 1 round of at most two class lenses (docs: one doc lens such as `harness-engineering`; tooling: `premortem`; sources: `architecture`; others: `devils-advocate`). A fix check only with Act-on items. |
| `risk: yes` | Step 3 of the **interrogate** skill picks the lenses. |

- With `risk: yes`, each guard in a risk path gets two mutation controls, replayed once in Phase 7. With `risk: no`, the failing-before test is the control, with no replay. Decision 0028 says when a plan raises a guard to risk. A sources change also gets a screenshot or AX check per visible criterion. A tooling control is a failing case in its `.test.sh`.
- Each gate has `maxRounds: 2`; round 2 runs only on a critical item, or with `risk: yes` on a warning.

## Phase 3: Plan gate

Run `scripts/check-plan.sh <run folder>`: it must exit 0. Then run the **interrogate** skill with target `plan` and the lenses of the class table. Keep `Sources/` and `Tests/` unchanged until the gate closes; prototype in the run folder only.

- Change the plan for each "Act on" item and log it. Grep each fact that a fix changes, as in Phase 2.
- Round 2 runs only as the class table section says. After the last round and the fix check, the gate is closed: record open risks in `run.md`.

## Phase 4: Implement

1. Each slice follows the **tdd** skill. No other check runs before a commit. Commit the slice before a file of the next slice.
2. Use Conventional Commits (see `AGENTS.md`).
3. After each slice, log a row and tick `run.md` with the actual minutes. Time `make test` on `main` once per run, and log the branch time. At two times the `main` time, stop and treat the cost as a plan change.
4. If the plan proves wrong, stop, update `plan.md`, and log why.
5. A slice that changes what a user sees or does updates `docs/guide.md`. Before its first commit, check the change on screen in the verify copy (`.claude/skills/verify-this/references/driving-the-app.md`), with the screenshot path in its `decisions.tsv` row: `<verdict>, on screen, <screenshot path>`.

## Phase 5: Clean up

Run the **deslop** skill. Commit the cleanup on its own.

## Phase 6: Code gate

Before the gate, run `scripts/check-changed.sh origin/main`. When its classes or risk are higher than in the plan, go back to Phase 2 for the controls and the rounds, and log a row.

Run the **interrogate** skill with target `diff` and the lenses and rounds of the class table.

- Fix each "Act on" item in its own commit, a bug fix with its regression test.
- Put each "Consider" item that you skip in `## Later`, with the reason.
- When a user decision reverts a fix, write its symptom in the manual checks and in `pr.md`.
- Run the rounds as in Phase 3. Out-of-scope findings go to `## Later`.

## Phase 7: Verify

Run the **verify-this** skill for each criterion against the real artifact (the built app, real files, measured levels), and record each verdict in `run.md`. `NOT VERIFIED` gets a `decisions.tsv` row with the result `NOT VERIFIED` and sends you back to Phase 4 for a test-first fix; first stop running replays (`pkill -INT -f mutate.py` restores the file). With `risk: yes`, when you replay the controls once on the tree that lands, read `references/mutation-controls.md`. If the window changed, make the screenshots again (`docs/guide.md`, For contributors). After the last Phase 7 fix, run once, with logs in `<run>/logs/`: each eval that `scripts/evals-for.sh --quoted origin/main` prints, `make bench` and `scripts/bench-pairs.sh` for each optimized budget (`references/performance-criteria.md`; a slice runs its bench until it passes and runs no pairs), `scripts/check-governance.sh origin/main <run>`, then the push check `make check-changed BASE=origin/main` with `run_in_background`. Commit nothing until it ends: `scripts/land.sh` reuses its stamp. Tell the user the state of a background step that runs over 15 min. A later `Sources/` change runs the bench, the pairs, and the push check again. A later doc change runs its evals again.

## Phase 8: Reflect

Run the **reflect** skill on the branch. Then review the `## Later` headings, and move each item that this run made due to `## Next`.

## Phase 9: Land through a pull request

1. Write `<run>/pr.md` with the **pr** skill. Then run `scripts/land.sh "<plain title>" <run>/pr.md`. Run it with `run_in_background`. Read its output for the `pr:` and `range:` lines.
2. If the land stops on a conflict, resolve it with a rebase on a fresh branch. Leave a leftover local branch after the merge. Record the conflict and the branch in `run.md`.
3. Set `run.md` to `done` with a summary: what landed (PR, commit range), what is verified, manual checks, and open risks. It and the PR body list each default "open for the user", with the run that must stop for it. Write the PR URL in `run.md` and the ledger.

## Long autonomous runs

When one session runs several goals or an unattended loop, read `references/long-runs.md` before the first run.
