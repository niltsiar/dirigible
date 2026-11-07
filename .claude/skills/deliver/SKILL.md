---
name: deliver
description: "Deliver one goal end to end: analyze, plan, gate, implement test-first, review, verify, reflect, and land. Use for /deliver, 'implement R3', 'build the next feature', or any autonomous run."
---

# Deliver

One run takes one goal (a requirement, a slice, or a bug) to a merged pull request on `main`. Every step writes to the run ledger. Open a todo list with the phases. Do not skip a phase; a short phase leaves its artifact.

## Autonomy rules

- For reversible work (AGENTS.md, Git), choose a default, log it in `decisions.tsv`, and continue. Its row result starts with `default`; its why and the PR body name what reverses it (`Reverse:`). `scripts/land.sh` needs no question. A privacy prompt of the verify copy: `driving-the-app.md`.
- A row result starts with its token when one applies: `failed` or `fail` (a check failed, not a planned red), `flake`, `survived` (a mutant), `NOT VERIFIED`, or `missed unknown`. A token wins over `default`; then start the decision with `default`. A row can change the text or the value of a criterion. That row is a criterion change. Edit `analysis.md` first, then start the decision with `criterion change` and name the criterion ID and its old and new value (`log-decision.sh` checks it).
- When a check needs hardware you cannot drive, write a manual check in `run.md` and do the closest automated check.
- Subagents do bulk reading and return conclusions. Start each phase, slice, and gate-fix agent as type `run-agent`, with the model of `docs/workflow/model-routing.md`. A subagent prompt names each run file that it writes as a required ledger file. An edit of `AGENTS.md`, `CODING_STANDARDS.md`, a skill, or an agent follows **writing-for-agents**, and a subagent prompt for such an edit names it.
- Send every research request through the **research** skill. While a loop or a bench runs, each subagent prompt says so: a `swift` ban alone is not enough.
- Each backlog write names its status (`scripts/wiki.py add <status> --from <file>`, the file written with the Write tool): `next` for a user request or a next-run item, `later` for a "Consider" item and all other deferred work.
- Before you fake or detect a failure of an external tool, probe it (exit status, stderr, files). Record each result in its `## Unknowns` row. The fake copies each result. Guard on the status and files. For a status with several causes, make your call print a marker text, and guard on that.

## Phase 0: Open the run

1. Run `scripts/wiki.py now` and `scripts/wiki.py list next --ready`, and read the last `run.md`; `scripts/wiki.py show <id>` prints an item. The **reflect** skill reads the lessons.
2. Find unfinished work: `git status --porcelain`, `git branch`, runs with status `open`. Resume one on its branch: run `git fetch origin` and `scripts/check-changed.sh --overlap origin/main`, and read its lines (information, never a stop). Read its `run.md` and `decisions.tsv`; compare its handoff with the git output, the last commit, and the PR state; log each difference; continue at the first unchecked phase. Do not switch to `main` with uncommitted changes.
3. For a new goal, run `.claude/skills/deliver/scripts/new-run.sh <slug> <type>`.
4. Run `scripts/with-lock.sh make check` on `main` only when `main` has commits no run landed. If it is red, the fix is the goal.
5. Before any file change, create the branch `<type>/<slug>` and write it in `run.md`. Every commit of the run goes on it. A run with several landings adds a `- Branch:` line to `run.md` when each next landing starts: `scripts/check-eval-keys.sh` reads the last line. `scripts/check-governance.sh` reads the branch of HEAD, and the last line only on a detached HEAD.

## Phase 1: Analyze

Fill `analysis.md` with the Edit tool (`new-run.sh` made its skeleton):

- The requirement IDs of `docs/requirements/brief.md`, and how Hindenburg PRO (the base) and other editors behave, with sources.
- Falsifiable acceptance criteria, each with its proving test or command. Each clause gets an assert or a named manual check that fails on the wrong behavior that the clause names. When two paths give one end state (two clocks, a cleanup after a write), assert where they differ: the input that disagrees, or a call count of the writer. A trigger (a command, a key) gets one case per start state: the window closed or shown, the focus in each control. A wait, a retry, or a long check also gets one case per state that another actor (a service, another run) reaches during it. Before the plan gate, run each criterion command that must print nothing at the base. Use a glob that leaves out the tests that assert the absence, and write each hit that stays. Run each planned grader once on a known-red input.
- A criterion for a refusal or a threshold has one input that meets it and one near input that does not, each with its expected state. A bar on data that arrives after the plan gate compares the change with the unchanged output on the same sample.
- The `## Unknowns` table (columns: `scripts/check-plan.sh`). The resolver is `code`, `probe`, `research`, `prototype`, `default`, or `user` (only for an irreversible step or a product choice with no reference behavior, and the run continues on a logged default). A question that is not sharp yet gets `split` and child rows. Resolve first the rows whose parent has an answer. A look-and-feel unknown gets `prototype` before the plan gate: a screenshot of a throwaway build in the probe sandbox, judged against the reference app.
- An untried limit is a guess. Probe a platform or tool limit before it moves a default from the reference behavior, turns a check manual, or weakens a criterion, under its original conditions (a test probe runs in the test runner); a stand-in signal or queue gets a slice test per difference. Before the plan gate, check each numeric plan rule with a probe or a worked fixture. Check each Reverse that changes a capped or counted value the same way. The probe or the fixture measures the statistic of the criterion over its span. Replay a new check on past inputs. Log each probe and replay.
- What is out of scope, as items with status later (`scripts/wiki.py add later --from <file>`).

## Phase 2: Plan

Fill `plan.md` with the Edit tool (`new-run.sh` made its skeleton):

- Vertical slices, each ending in a passing test and a commit. The riskiest unknown goes first. Types that reference each other share a slice.
- For each slice (a `###` heading): the first test, the modules, the commit message, and a `- Check:` line that gives its paths on stdin: `scripts/check-changed.sh --paths <<<$'<path>\n<path>'`. Each slice names the criterion IDs that it covers, and the test of its negative control. A planned red step of a test run expects any nonzero exit, not one exit value: make exits 2 when a recipe fails; a red step of a `.test.sh` file also expects the FAIL line of its new case.
- An `Agents:` line: the agent groups (small adjacent slices of one module share an agent), which groups run at the same time (no shared file or build output), and why the others wait.
- When a criterion sets a time budget or fixes a missed budget, adds a way to move or resize something, or a rule classifies loop runs, read `references/performance-criteria.md`.
- A bug goal proves its fix with its red repro log (tdd step 7). A refactor or a file split pins the behavior with a test before code moves, and reverts a move that deletes no branch, copy, or layer. A split by responsibility that keeps a file under the size limit is a gain.
- A one-way decision (a file format, a module boundary, a threading model, a dependency) gets the **architect** skill and a record in `docs/decisions/`.
- Grep `docs/decisions/`, `AGENTS.md`, and `CODING_STANDARDS.md` for each item. When an item changes a rule or a fact, grep its exact phrase and key terms in `docs/`, `Sources/` (comments too), `Tests/`, and the run files, and fix each copy in the same change. A test of the old rule is a copy, whatever input spelling builds the state: plan its old and new value. Quote each rule found and say if the plan keeps or changes it. A change amends that record. A probe in the record can refute a fix option.

### Checks by change class

`scripts/check-changed.sh` prints `classes:`, `targets:`, and `risk:` (decision 0028). `make check-changed` runs the targets.

| Run | Plan gate and code gate |
|---|---|
| Small (`risk: no`) | One subagent runs Phases 1-2 and returns the plan path. The lead runs the plan gate. One subagent runs Phase 4 and returns the commit range and the gate inputs. The lead runs the code gate. Each gate: 1 round of at most two class lenses (docs, comments: one doc lens such as `harness-engineering`; tooling: `premortem`; sources: `architecture`; others: `devils-advocate`). Each Act-on item gets the fix check, critical or not. |
| `risk: yes` | Step 3 of the **interrogate** skill picks the lenses. |

A workflow upkeep run uses the doc lenses of interrogate Step 3 in place of one doc lens. This holds at the plan gate and the code gate, for `risk: no` and `risk: yes`.

- The red-first log of a slice is its control, plus a screenshot or AX check per visible criterion of a sources change: no mutation control at slice time. `docs/decisions/0028-proportional-checks-and-reflect-governance.md` says when a plan raises a guard to risk. A tooling control is a failing case in its `.test.sh`.
- Each gate has `maxRounds: 2`; round 2 runs only on a critical item. The lead rules on each warning. The agent that applies the fixes reads the code, then writes each fix and each lead ruling under its item in the last `review-<gate>-<n>.md`; the fix check covers each fix. A fix that adds a condition to a guard with planned mutants: read `references/mutation-controls.md`, Pick the mutants.
- Light path: in a run whose classes are only `docs`, `comments`, or `tooling`, resume the agent that wrote the gate target (the Phase 1-2 agent, or the last implementer) with `SendMessage` for the gate fixes, and start no gate-fix agent. When it cannot resume, or its context is over the 150k line of `docs/workflow/model-routing.md`, the lead applies the plan gate fixes and a new agent of the slice model applies the code gate fixes. The Phase 7 agent is the last implementer, resumed; when it cannot resume or is over the 150k line, it is a new agent of the slice model. This holds also when the code gate has no Act-on item.

## Phase 3: Plan gate

Run `scripts/check-plan.sh <run folder>`: it must exit 0. Run the **interrogate** skill with target `plan` and the lenses of the class table. Keep `Sources/` and `Tests/` unchanged until the gate closes; prototype in the run folder only.

- Put each "Act on" change in `## Plan gate changes` with `Criteria:`, and log it. Grep each fact that a fix changes, as in Phase 2.
- After the last round and the fix check, the gate is closed: record open risks in `run.md`, and log a phase 3 row whose decision starts with `plan gate closed`; `log-decision.sh` runs `scripts/check-plan.sh` on it as on the first phase 4 row, and refuses the row until a `criterion change` row names each criterion that a plan gate change moves.

## Phase 4: Implement

1. Each slice follows the **tdd** skill. No other check runs before a commit. Commit the slice before a file of the next slice.
2. Use Conventional Commits (`AGENTS.md`).
3. After each slice, log a row and tick `run.md` with the minutes. Only the push check (`scripts/with-lock.sh make check-changed BASE=origin/main`) runs the full suite.
4. If the plan proves wrong, stop, update `plan.md`, and log why.
5. A slice that changes what a user sees or does updates `docs/guide.md`; a new or changed MCP tool, `dirigible` command, or recipe updates the agent manual (0051). Before its first commit, check the change on screen in the verify copy (`.claude/skills/verify-this/references/driving-the-app.md`), with the screenshot path in its `decisions.tsv` row: `<verdict>, on screen, <screenshot path>`.

## Phase 5: Clean up

Run the **deslop** skill in the last implementer agent. Phase 5 runs no test, and a rebase with no conflict runs no test: the push check runs on the final tree. Commit the cleanup on its own.

## Phase 6: Code gate

Before the gate, run `git fetch origin` and `scripts/check-changed.sh --overlap origin/main`, and read its lines: they are information and never stop the run. Then run `scripts/check-changed.sh origin/main`. When its classes or risk are higher than in the plan, go back to Phase 2 for the controls and the rounds, and log a row.

Run the **interrogate** skill with target `diff` and the lenses and rounds of the class table. Until the seat trial of 0028 (item 1115) closes, run its two seats at round 1.

Run no push check at the gate. Phase 7 runs the one push check, after the last gate fix.

When a slice or a gate fix adds or changes an `evals.md` key, the lead runs `scripts/eval/run.sh` for its IDs in the background before the next phase 6 row: `log-decision.sh` refuses the row until the key has a grade. A run agent returns to the lead.

- Fix each "Act on" item and each flake in its own commit: a behavior fix with its regression test, a rule fix with the Phase 2 grep. Check a visible fix as in Phase 4 step 5.
- Add each skipped "Consider" item with status later (`scripts/wiki.py add later --from <file>`), with the reason.
- When a user decision reverts a fix, write its symptom in the manual checks and in `pr.md`.

## Phase 7: Verify

One closing agent (the model of a slice) runs this phase up to `scripts/check-governance.sh`, then Phase 8 and the PR text. Its brief allows the reflect agent (reflect step 2). On the light path (the light path bullet of Checks by change class), no closing agent starts: the Phase 7 agent runs this phase up to `scripts/check-governance.sh`, and the lead runs Phase 8 and writes the PR text. A step over 10 min (`scripts/bench-pairs.sh`, the mutation pass, `scripts/eval/run.sh`, `scripts/eval/agent-tasks.sh`) starts in the lead, in the background (AGENTS.md, Commands), before the closing agent or the Phase 7 agent, which reads the log.

Run the **verify-this** skill for each criterion against the real artifact (the built app, real files, measured levels), and record each verdict in `run.md`. `NOT VERIFIED` gets a `decisions.tsv` row with the result `NOT VERIFIED` and sends you back to Phase 4 for a test-first fix, whose red-first log is its control; first stop the mutation pass (`pkill -TERM -f "mutation-pass.sh <absolute-worktree>"` restores the file; exit 143). If the window changed, make the screenshots again (`docs/guide.md`, For contributors). After the last Phase 7 fix, run once, with logs in `<run>/logs/`: `scripts/eval/run.sh` for each ID that `scripts/evals-for.sh --quoted origin/main` prints, `scripts/bench-pairs.sh` for each optimized budget (`references/performance-criteria.md`; a slice runs its bench until it passes and runs no pairs), with `risk: yes` the mutation pass of `references/mutation-controls.md` (each mutant with `--timeout`, logs in `<run>/controls/`), a `run.md` line `- Lands: <F-IDs>` or `- Lands: none` and a commit of the `features.md` states of those IDs, `scripts/check-governance.sh origin/main <run>`. When `scripts/check-changed.sh origin/main` prints a `targets:` line with `check` or `check-fast`, the lead runs `WITH_LOCK_MAX_WAIT=0 scripts/with-lock.sh make test-hooks DIRIGIBLE_HOOKS_ALL=1 > <run>/logs/hooks-pass.log 2>&1` in the background (AGENTS.md, Commands). The lead starts the push check `scripts/with-lock.sh make check-changed BASE=origin/main > <run>/logs/push-check.log 2>&1` in the background (AGENTS.md, Commands), after exit 0 of a pass, on the same day. After another exit, the lead reads the log, then fixes the cause or runs the pass again. This run's newest `test-shards:` time, over two times that of the newest landed `push-check.log` with a `test-shards:` line (else the baseline of this run), is a plan change. Commit nothing else until it ends: `scripts/land.sh` reuses its stamp. For an agent row (E38) that `scripts/evals-for.sh --quoted origin/main` prints, the lead runs `scripts/eval/agent-tasks.sh` in the background after the push check, on a CLI copy built after the last `Sources/DirigibleCore`, `Sources/DirigibleCLI`, and `Sources/DirigibleMCP` commit; `scripts/eval/run.sh` prints its call. It runs with the prefix `WITH_LOCK_MAX_WAIT=0 scripts/with-lock.sh` (AGENTS.md, Commands), because it loads the CPU. Tell the user the state of each background step over 15 min. A later `Sources/` change runs the pairs and the push check again. A later doc change runs its evals again, and a later fix verifies each criterion whose proof files it touched; for a fix that changes `Sources/` or `Tests/`, the lead runs the fix check of `.claude/skills/interrogate/references/lead-judgment.md`, with its `decisions.tsv` row as the finding.

## Phase 8: Reflect

The closing agent (on the light path, the lead) runs the **reflect** skill on the branch. It moves each later item that this run made due to status next (`scripts/wiki.py move <id> next`), and each taken item out (`scripts/wiki.py move <id> done`; `check-governance.sh` fails the land).

## Phase 9: Land through a pull request

1. Phase 7 wrote `- Lands:` and set the `features.md` states, and the closing agent (on the light path, the lead) wrote `<run>/pr.md` with the **pr** skill, up to step 6 of **writing-for-humans**. While the push check runs, one Sonnet agent reads `pr.md` as the cold reader (step 7); the lead revises each misread sentence. When the check passes, run `scripts/land.sh "<plain title>" <run>/pr.md` in the background (AGENTS.md, Commands). Read its `pr:` and `range:` output lines. Read each `open run` line too. Add it with the Edit tool under `## Handoff` of that run's `run.md`. Add the heading when it is missing.
2. If the land stops on a conflict, resolve it with a rebase on a fresh branch. Leave a leftover local branch after the merge. Record the conflict and the branch in `run.md`. If it stops with the PR open, run the same command again; the header of `scripts/land.sh` says what a second call does.
3. Set `run.md` to `done` with a summary: what landed (PR, commit range), what is verified, manual checks, and open risks. The lead decides each default: `run.md` and the PR body name it and how to reverse it, and list no open item. Write the PR URL in `run.md`. `scripts/land.sh` appends the done row of the run to the run log after the merge.
4. Before the teardown, move each real-voice recording to `.scratchpads/corpus/` or name it in `run.md`. Then, from the main checkout, run `scripts/teardown-run.sh <run folder>`. It deletes only build output (`*.app`, `.build/`, `*.dmg`). It moves each other candidate, also an audio file that no text file names, to `.scratchpads/trash/`, and never deletes it. On exit 1, commit or copy the named change, then run it again.

## Long autonomous runs

When one session runs several goals or an unattended loop, or faces a wait over 4 h, read `references/long-runs.md` before the first run or the wait.
