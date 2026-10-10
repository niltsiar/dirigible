# 0028. Checks in proportion to the change, and rules that govern reflect

- Status: accepted
- Date: 2026-10-01
- Accepted: 2026-09-30, after plan gate rounds 1 and 2 of run `2026-09-30-workflow-consolidation`.
- Amended: 2026-10-01. A commit inside a slice can run only the tests of the slice. A passing push check writes a stamp that the land reuses. After a fix that follows the replay, only the affected controls replay again. Reflect rule 8 also runs the scenarios after a trim of a rule.
- Amended: 2026-10-02 (run `2026-10-02-speed-run`, user decisions). The pre-commit hook runs only lint, and no check is required before a commit. The push adds `test-slow` only for risk, a changed slow test, a Makefile change, or the first push of the day with Swift tests. A small run gets trimmed gates. Reflect logs learnings only; an upkeep run applies the rule changes.
- Amended: 2026-10-08 (run `2026-10-08-workflow-speed-3`, user request). `scripts/run-checks.sh` runs the targets of `make check-changed` and of the land delta with `make -k`. When only `test` or `test-slow-push` is red, it reruns only the failed Swift tests: up to 3 tries, or 1 try with `risk: yes`. A pass on a rerun writes the stamp, and `scripts/land.sh` writes a `flake` row for each test that passed only on a rerun. The flake triage still applies. The push runs `make test-slow-push`: the slow tests with no bench file of `PUSH_SKIP` in the Makefile, because a fast test holds each assert of those files. A changed `PUSH_SKIP` file runs `make test-slow`, the full slow suite, which also stays a target to run by hand.
- Amended: 2026-10-08 (run `2026-10-08-bench-asserts`). Fast tests and one slow test that is not a bench hold the unique asserts of 13 more bench files, so `PUSH_SKIP` lists them too.
- Amended: 2026-10-09 (run `2026-10-08-upkeep-batch-6`, upkeep DLV-131). A changed `PUSH_SKIP` file runs its own slow tests with `make test-slow-push PUSH_RUN=<names>`, not `make test-slow`. The other bench files of `PUSH_SKIP` stay skipped.
- Amended: 2026-10-10 (run `2026-10-10-upkeep-batch-7`, user decision on the code-review trial). At a code gate with a class other than docs, the `code-review` skill replaces the code-quality lens: `high` on the branch in round 1, and `medium` on the fix range as round 2, in place of the convergence panel. It runs on a clean committed tree with no `mutate.py` run, and the fixer checks each finding. The plan gate lenses do not change.
- Amended: 2026-10-10 (run `2026-10-10-comment-only-class`, user complaint about a 45 min push for 3 comment lines). In the git modes, the content of a change can give the class. A change of only `//` lines and blank lines in a `Sources/` or `Tests/` Swift file is class `comments` (`check-fast`), also in a floor file, so `risk: no`. A change of only `#` lines and blank lines that make skips in the `Makefile` is class `docs`. Neither change counts for the push `test-slow-push` rule. A new, deleted, or untracked file, `Package.swift`, a Swift file with a multi-line string, and a Makefile with `define` keep the path class. `--paths` stays path-only, and a path argument after it exits 2. At a gate, the class `comments` gets one doc lens and no `code-review` round, as docs does.
- Supersedes: the check rule of `AGENTS.md` ("Run it before every commit" in the `make check` row, and "One commit is one logical change that builds and passes `make check`" in Git). The new text of `AGENTS.md` comes in a later commit of the same run. Until then, this record and the plan of that run apply.

## Context

Every commit ran the full `make check`, about 270 s, also for a one-line docs change. Every guard got mutation controls, and every killed control ran again in the verify phase. The start-window run (`2026-09-30-start-window`) is the cost baseline: about 18 h of wall time, 114 mutation controls, 22 full `make check` runs, and a replay of the controls that took 6 h.

The workflow docs grew by one rule for each learning. The reflect skill added a rule after one occurrence, and no rule limited the size of a skill. The same rule had copies in several files, and some copies did not agree.

## Decision

### Change classes

- `scripts/check-changed.sh` owns the change classes, the path table, and the risk floor. Docs name the script. They do not copy the table or the paths.
- The script prints three lines: `classes:`, `targets:`, and `risk:`. With no argument, it prints the make targets for one commit. With a base, it prints the targets before the push.
- `make check-changed` runs the targets of the changed paths. No check is required before a commit. `make check-changed BASE=origin/main` runs the targets before the push. The recipe exits nonzero when the script fails, and runs no target for `targets: none`.
- With `FILTER='<name> <name>'`, the target `test` becomes `test-filter`, which runs only the tests that match a name. It fails when no test ran. The tdd loop uses it. `FILTER` with a base exits 1.
- A passing check with a base, on a clean tree that did not change, appends a stamp line (`scripts/check-stamp.sh`): the commit, the base commit, and the targets. `scripts/land.sh` runs no check when the stamp has HEAD and the base is `origin/main`. When the stamp has an ancestor of HEAD, it runs the push targets of the later commits only.
- A path that no row matches is class `build`, which runs the full `make check`. A new kind of path is slow, but safe.
- The script fails closed. A git error exits nonzero. An empty list against a base exits 1.
- A plan can raise a guard outside the risk floor to risk when its defect loses data or breaks audio. It logs the reason in `decisions.tsv`. A plan cannot lower a floor path. `scripts/check-changed.test.sh` fails when a floor path does not exist.
- `make test-slow` runs only the slow tests, and a pass writes the date of today. `make test-slow-push` runs them with no bench file of `PUSH_SKIP`, and a pass also writes the date. Before the push, `check` runs first. The push adds `test-slow-push` only for `risk: yes`, a changed slow test, a Makefile change, or a push with `check` when no slow run passed today on this clone.

### Mutation controls and the replay

- Mutation controls and the replay key on the `risk:` line, not on the class.
- With `risk: yes`, each guard in a risk path gets two controls: one for "accepts too much" and one for "refuses too much". Each control has a timeout. The controls replay once, in the verify phase, on the tree that lands. After a fix that follows that replay, only the controls that `.claude/skills/deliver/scripts/replay-list.sh` lists replay again: their mutated file or their killing test file changed.
- With `risk: no`, there are no mutation controls. The failing-before test is the control, and there is no replay.

### Review panel scale

| Run | Review panel |
|---|---|
| Small: `risk: no` | Amended 2026-10-10. Plan gate and code gate: 1 round of at most two lenses that match the classes, and `code-review` at a code gate with a class other than docs or comments. Round 2 only on a critical item. A fix check only with Act-on items. One subagent runs Phases 1-2 and 4; the lead runs the gates. |
| `risk: yes` | Amended 2026-10-10. Plan gate and code gate: 2 rounds at most, with the lenses of each class. Round 2 runs only on a critical item or a warning, and it is the convergence round only. At the code gate, `code-review` replaces the code-quality lens, and round 2 is `code-review` `medium` on the fix range. |

### Word budgets

- `docs/workflow/budgets.tsv` gives a word limit for each workflow doc, a total for each skill folder, and one `TOTAL` row. `make check-docs` checks the limits.
- A limit goes up only in a commit that names a `decisions.tsv` row in the `decision` cell. Before the push, `scripts/check-governance.sh` refuses a row that goes up with no `decisions.tsv <time>` in that cell.
- A rewrite sets the row of its file to `wc -w` x 1.1, rounded up to the next 10 (about 9% free), so the next reflect run has free words.

### Rule register

- `docs/workflow/rules.tsv` has one row for each normative statement of the workflow docs. Each row has a stable ID, a file, a verdict, a target, a reason, a source, a cause key, and a one-clause summary. It holds no verbatim rule text.
- The verdicts are `keep`, `move`, `merge`, `enforced`, `delete`, and `new`.
- `make check-docs` checks the structure of the register. It does not compare rule text with the target file.

### Reflect rules

1. A learning on its first occurrence becomes one line in `learnings.md` with the tag `seen-once`, the run slug, and a cause key. It does not change a skill.
2. A key match is only a candidate. A learning is a second occurrence when the synthesizer records the earlier line and the shared cause. A second occurrence becomes an upkeep item in `## Next` of the backlog (amended 2026-10-02: a reflect run makes no commit). A check, a script, or a hook comes before a sentence. A high-cost first occurrence (lost data, lost user input, a destroyed file outside the repo) can skip to this step, with the reason in the commit body.
3. A change replaces or merges text in the same section, so the file stays within its budget. When it cannot, the item goes to the `## Later` section of the backlog.
4. Each change updates `docs/workflow/rules.tsv` in the same commit.
5. Once per upkeep run, before the merge, the review panel reviews the diff of the batch. The lenses come from the paths of the diff. A blocking finding gets a fix commit or a revert commit.
6. When 8 or more upkeep items wait, the next run is a workflow upkeep run, which applies them all (amended 2026-10-08: 3 before).
7. A reflect run or an upkeep run removes at most one rule. The reflect skill holds the full removal rule. In a branch whose only class is docs, `scripts/check-governance.sh` refuses more than one removal when the run has a reflect row.
8. An upkeep run runs once, for the batch, the eval scenarios of `docs/workflow/evals.md` that name a changed file. A scenario that passed before the change and fails after it reverts the change. A changed file with no scenario gets one first, or the commit body says why none applies.

## Consequences

- A docs commit runs `check-docs` in seconds, not the full suite. The push runs the targets that `scripts/check-changed.sh <base>` prints, or reuses a stamp.
- A commit can break a test that no loop ran. The push check finds it.
- The replay after a fix misses a control that only a change in a caller in a third file makes unreachable.
- The path table is one place to change. A wrong class lets a red commit through, so its test compares the whole output for each class and checks the fail-closed exits.
- Fewer mutation controls run. A defect in a guard outside the risk floor can land when its failing-before test is weak. The plan can raise such a guard to risk.
- The workflow docs stop growing by one rule for each learning. A rule that does not fit the budget waits for a consolidation run.

## Follow-up count

For each of the next two deliver runs, count the full `make check` runs, the mutation controls, the replays, and the wall hours. Compare each count with the baseline above. The count is not a gate of the run that made this record.
