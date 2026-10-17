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
- Amended: 2026-10-12 (run `2026-10-12-pipeline-reuse`). The pre-commit hook also runs `scripts/check-sizes.sh` and `scripts/check-waits.sh` before lint, so it is no longer lint only. Each is a grep under 1 s, so a red size or wait gate stops the commit, not a push check after the Swift tests. For the goal `check` or `check-fast`, `scripts/run-checks.sh` runs the gates of `STATIC_GATES` in the Makefile first, and a red gate stops the check before the Swift targets.
- Amended: 2026-10-13 (run `2026-10-13-controls-on-demand`, user question on the value of the controls). The red-first log of each slice is its control at each risk level. No control runs at slice time, and no control replays. A `risk: yes` run gets one mutation pass on the landing tree after the last code gate fix: one mutant for each data-safety guard on the changed lines, with no cap, and one for each other risk guard while the total is under 6, at least 3 when the guards allow. In 58 runs with about 2,988 control logs, no surviving control found a product bug, and 5 gave a stronger test (one of them, C10c, through the code gate).
- Amended: 2026-10-15 (run `2026-10-14-workflow-upkeep-2`, release-path change 2). After a pass stamp S of the base, `scripts/check-changed.sh <base>` prints `stamp: delta <S>` and the targets of the paths changed since S only. The classes and the risk stay those of the whole base diff, and `test-slow-push` comes from the risk of the paths since S. When the only red targets of a check with a base on a clean tree are tests, `scripts/run-checks.sh` appends a partial stamp line with the names that stay red after the reruns. The next `scripts/check-changed.sh <base>` gives the targets of the paths since that line and a `RERUN=` word, and `scripts/run-checks.sh` runs the names of the word after the other targets, with one flake line for each name that passes. On a `risk: yes` branch with no `Sources/` or `Tests/` change since the line, the check refuses the rerun.
- Amended: 2026-10-15 (run `2026-10-14-workflow-upkeep-2`, user decisions B10 and B11). Each word limit keeps 1 % room, in place of the x 1.1 rule of a rewrite. A branch raises `TOTAL` by 50 words at most, and a consolidation round trims `TOTAL` back to the `QUOTA` row.
- Amended: 2026-10-15 (run `2026-10-14-workflow-upkeep-2`, user decisions C and D of the smarter workflow). Round 2 of a gate runs only on a critical item at each risk level: the lead fixes each warning, and the fix check covers it. The `code-review` skill runs only in round 1 of a `risk: yes` code gate.
- Amended: 2026-10-17 (run `2026-10-17-workflow-speed`, replaces release-path change 1 of 2026-10-15). The code gate starts no push check. One push check runs in Phase 7, after the last code gate fix, so it is the check of the landing tree.
- Amended: 2026-10-15 (run `2026-10-15-land-stamp-reuse`, user request: the land ran the full push check again after its rebase). The rebase rewrites each commit, so no stamp commit was an ancestor of the rebased HEAD. `scripts/land.sh` now reads the pass stamp before the rebase and runs the targets of `git diff --name-only --no-renames <stamp commit> HEAD`. A delta path outside `Sources/` and `Tests/` that a code line of `Tests/` names as a whole string-literal path (a quote or a `/` before it, a quote after it; a comment does not count) also adds the target of that test file (`test-app` for `AppBundleTests`, `test-dmg` for `DiskImageTests`, else `test`), because a Swift test can read a file of another class (`docs/guide.md`). A land that stops after the rebase keeps the stamp commit in the file `dirigible-land-stamp-<branch with / as ->` of the common git dir until the merge, and `scripts/check-stamp.sh read <base> <commit>` finds its line with no ancestry test.
- Amended: 2026-10-15 (run `2026-10-15-land-stamp-reuse`, same request). Another land between the push check and the land moves `origin/main`. `scripts/check-stamp.sh read <base>` therefore takes a line whose base is the commit of `<base>` or an older commit of it; a base that is a branch commit stays refused. The reader tests the lines of this branch only (`git rev-list HEAD --not <base>`), so its git calls do not grow with the stamp file. `scripts/check-changed.sh <base>` gives the same delta after such a stamp; a partial line still needs the exact commit of `<base>`.
- Amended: 2026-10-17 (run `2026-10-17-swift-concurrency-skill`, user decision). A vendored skill has vendored rows in `docs/workflow/budgets.tsv`, outside `TOTAL`.
- Supersedes: the check rule of `AGENTS.md` ("Run it before every commit" in the `make check` row, and "One commit is one logical change that builds and passes `make check`" in Git). The new text of `AGENTS.md` comes in a later commit of the same run. Until then, this record and the plan of that run apply.

## Context

Every commit ran the full `make check`, about 270 s, also for a one-line docs change. Every guard got mutation controls, and every killed control ran again in the verify phase. The start-window run (`2026-09-30-start-window`) is the cost baseline: about 18 h of wall time, 114 mutation controls, 22 full `make check` runs, and a replay of the controls that took 6 h.

The workflow docs grew by one rule for each learning. The reflect skill added a rule after one occurrence, and no rule limited the size of a skill. The same rule had copies in several files, and some copies did not agree.

## Decision

### Change classes

- `scripts/check-changed.sh` owns the change classes, the path table, and the risk floor. Docs name the script. They do not copy the table or the paths.
- The script prints three lines: `classes:`, `targets:`, and `risk:`. With no argument, it prints the make targets for one commit. With a base, it prints the targets before the push.
- `make check-changed` runs the targets of the changed paths. No check is required before a commit. `scripts/with-lock.sh make check-changed BASE=origin/main` runs the targets before the push. The recipe exits nonzero when the script fails, and runs no target for `targets: none`.
- With `FILTER='<name> <name>'`, the target `test` becomes `test-filter`, which runs only the tests that match a name. It fails when no test ran. The tdd loop uses it. A local `check` becomes `check-fast test-filter test-app`. A local run with no `FILTER` and a Swift test target exits 1. `make test` refuses unless the push check or `DIRIGIBLE_FULL_SUITE=1` allows it. `FILTER` with a base exits 1.
- A passing check with a base, on a clean tree that did not change, appends a stamp line (`scripts/check-stamp.sh`): the commit, the base commit, and the targets. `scripts/land.sh` reads the stamp before its rebase. After the rebase, it runs no check when the stamped tree is the tree of HEAD, and else it runs the push targets of the files that differ between them. A stamp is usable when its base is the commit of `origin/main` or an older commit of it.
- A path that no row matches is class `build`, which runs the full `make check`. A new kind of path is slow, but safe.
- The script fails closed. A git error exits nonzero. An empty list against a base exits 1.
- A plan can raise a guard outside the risk floor to risk when its defect loses data or breaks audio. It logs the reason in `decisions.tsv`. A plan cannot lower a floor path. `scripts/check-changed.test.sh` fails when a floor path does not exist.
- `make test-slow` runs only the slow tests, and a pass writes the date of today. `make test-slow-push` runs them with no bench file of `PUSH_SKIP`, and a pass also writes the date. Before the push, `check` runs first. The push adds `test-slow-push` only for `risk: yes`, a changed slow test, a Makefile change, or a push with `check` when no slow run passed today on this clone.

### Mutation pass

- The mutation pass keys on the `risk:` line, not on the class.
- At each risk level, the red-first log of each slice is its control. No mutation control runs at slice time, and no control replays.
- With `risk: yes`, one mutation pass runs on the landing tree, after the last code gate fix and before the push check. One agent picks one mutant for each data-safety guard on the changed lines, with no cap, and one for each other risk guard while the total is under 6. With fewer than 3, it adds another direction of the riskiest guard. With no guard on the changed lines, a logged row says why no pass applies. Each mutant runs once, with a timeout. `scripts/land.sh` needs its phase 7 row, not older than the last `Sources/` commit: a fix after the pass runs one new mutant for each guard that it touched, and a fix that touches no guard gets a row that says so.
- With `risk: no`, there is no mutation pass.

### Review panel scale

| Run | Review panel |
|---|---|
| Small: `risk: no` | Amended 2026-10-15. Plan gate and code gate: 1 round of at most two lenses that match the classes, and no `code-review`. Round 2 only on a critical item. Each Act-on item gets the fix check, critical or not. One subagent runs Phases 1-2 and 4; the lead runs the gates. |
| `risk: yes` | Amended 2026-10-15. Plan gate and code gate: 2 rounds at most, with the lenses of each class. Round 2 runs only on a critical item, and it is the convergence round only. At the code gate, `code-review` replaces the code-quality lens in round 1 only. |

### Word budgets

- `docs/workflow/budgets.tsv` gives a word limit for each workflow doc, a total for each skill folder, and one `TOTAL` row. `make check-docs` checks the limits.
- A limit goes up only in a commit that names a `decisions.tsv` row in the `decision` cell. Before the push, `scripts/check-governance.sh` refuses a row that goes up with no `decisions.tsv <time>` in that cell.
- Each limit keeps 1 % room: a file row is at least `wc -w` x 1.01, rounded up, and a folder row and `TOTAL` are at least the sum of those values. The `QUOTA` row is the `TOTAL` of the last consolidation. A branch raises `TOTAL` by 50 words at most, unless its `QUOTA` row is at or above its new `TOTAL` (`scripts/check-governance.sh`). When `TOTAL` is 250 or more words over `QUOTA`, `new-run.sh` prints `consolidation due`, and the next workflow upkeep run trims the docs until `TOTAL` is at `QUOTA` again.
- A third-party skill under `.claude/skills`, listed in `.claude/skills/THIRD_PARTY.md`, has vendored rows: the decision cell of the folder row and of each file row starts with `vendored:`. A vendored row caps its folder or file, and its words stay out of `TOTAL`. The cap stops our own rules from piling up. A pinned vendored text does not grow by learnings. A project edit of a vendored file stays under the cap of its own row.

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
- A guard with no pick in the pass can land with a weak red-first test. The next 5 risk runs measure the picks in the `## Next` item "mutation pass trial" of the backlog; a defect that a mutant of a left-out guard kills brings back one mutant per guard. An upkeep run closes the trial.
- The path table is one place to change. A wrong class lets a red commit through, so its test compares the whole output for each class and checks the fail-closed exits.
- Fewer mutation controls run. A defect in a guard outside the risk floor can land when its failing-before test is weak. The plan can raise such a guard to risk.
- The workflow docs stop growing by one rule for each learning. A rule that does not fit the budget waits for a consolidation run.

## Follow-up count

For each of the next two deliver runs, count the full `make check` runs, the mutation controls, the replays, and the wall hours. Compare each count with the baseline above. The count is not a gate of the run that made this record.
