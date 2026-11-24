# Whole-workflow review: cursor/plugins, pstack, mattpocock/skills

Date: 2026-10-01

Method: shallow clones of `cursor/plugins` at `2eb7ed4` (2026-09-30) and `mattpocock/skills` at `d81f3a1` (2026-09-29), plus `gh api` compares against our pins (`b42effe`, `c55ee46`). Read in full: the poteto-mode SKILL and the playbooks quoted here, blast-radius, figure-it-out, create- and maintain-verification-skill, attack-the-premise, how, comment-sicko, the cursor-team-kit skills and agents named here, thermo-nuclear-code-quality-review (first 9000 characters), mp code-review, retro, implement, implement-spec, prototype, tdd, handoff, loop-me, wait-what. Part read: codebase-design, improve-codebase-architecture. From `fog-of-war.md`: grilling, wayfinder. Description only (NOT VERIFIED beyond it): every other item named, for example control-ui, control-cli, thermo-nuclear-review, pr-review-canvas, arena, swarm, why, teach, recall, automate-me, opening-a-pr, shipping, babysit, autopilot-*, make-bot-ui, dyl-stack, benny, triage, wizard, to-tickets, ask-matt, claude-handoff, setup-pre-commit, writing-*. Dex Horthy and Emil Kowalski items come from `dex-emil.md` (paraphrase, NOT VERIFIED verbatim). Prefixes: `cp:` = cursor/plugins, `mp:` = mattpocock/skills/skills. Evidence: the local learnings file of that date (not in git; L = line), the run ledger, and a grep of 2806 `decisions.tsv` rows.

## 1. Failure classes of the week, and the upstream item that fits

| Class | Evidence | Upstream item that prevents or shortens it | Status |
|---|---|---|---|
| Flaky timing tests | about 35 learnings (L31-36, 46, 54, 63, 72, 76-77, 85-88, 97-103, 108, 153, 170-172, 184, 194); "flake" in 112 rows of 23 runs | mp `diagnosing-bugs` (we have it); pstack `principle-attack-the-premise` census script (we have `scripts/flake-monitor/`); poteto `runtime-forensics` "prove the mechanism" (in our tdd) | Covered. No upstream gain. |
| In-process test passes, screen fails; late on-screen defects | L82, 109, 110, 121, 122, 133, 187, 188; 9 on-screen NOT VERIFIED in Phase 7 of 5 runs (mouse-edits, header-panel x2, ui-shell A12, start-window M4 and C8, live-take V1-V3) | pstack `visual-parity` (image diff against a baseline, a nonzero diff fails); `create-verification-skill` (feature map); poteto `prototype` playbook | Plan D2 adds an early look check (prose). Recs 2, 4. |
| Verify copy set up by hand each time | L166, 180, 190, 193, 195; a backlog item of 2026-10-01 | pstack `create-verification-skill` sections Launch, Doctor, Helpers, Cleanup | Rec 1. |
| Criterion or scope drift not seen by a gate | L162 and L189 (second occurrence), L192 (Phase 7 fixes with no diff round) | mp `code-review` Spec axis; pstack `shipping` ("Green is not safe") | Rec 3. |
| Plan gaps found by the gate | L16, 19, 43, 53, 62, 71, 114-116, 127, 169, 185; "plan change" in 61 rows of 19 runs | mp `grilling`/`wayfinder` frontier; pstack `check-plan.mjs`; pstack `blast-radius` | Plan D2 (Unknowns), S5 (check-plan). Rec 5. |
| The same invariant fixed round after round | L16 (five rounds), L19, L43 (three rounds), L53, L71, L191 | pstack `principle-attack-the-premise` (write the premise before the next fix) | Principle exists; no trigger in interrogate. Rec 6. |
| Stale copies of a changed rule | L115, 116, 127, 162, 195 | pstack `refactoring` playbook ("Renames silently miss usages in strings, prose, and back-references") | Covered by deliver Phase 2 grep and `rules.tsv`. No gain. |
| Side effects of a probe or a drive | 4 incidents (export: files in `~`; timeline-navigation: Mission Control; start-window: Apple menu Clear, real preferences); L132 | pstack `create-verification-skill` ("Never kill by process name; kill what you started"; check what a dry run skips) | Covered by `probe.sh`, `ax.swift` menu paths, the verify copy. Rec 1 adds a PID stop. |
| Tooling written again ad hoc | L94, 107, 135, 138, 157, 190 | pstack `principle-build-the-lever` (we have it) | Covered, except rec 1. |
| Budget misses | timeline-view C9, timeline-scroll 9b, timeline-navigation N25, live-take P4; L33, 57, 59, 81, 134, 139, 141 | poteto `perf-issue` (trace first, eight strategy families); `hillclimb` (prove the harness separates workloads; keep or revert each attempt) | Mostly covered by `performance-criteria.md` and `bench-pairs.sh`. Rec 7. |
| Repeated checks, benches, replays; idle orchestrator | brief items 1-3, 9; L177 | poteto `autonomous-run` watcher; cp `ci-watcher`; mp `implement-spec` background implementers | Plan S1-S3, D2, D5. |
| Hook false positives | L13, 15, 18, 40, 41, 186 | mp `git-guardrails-claude-code` (our source; unchanged upstream) | Ours is ahead. No gain. |
| Reflect cost | consolidation and live-take: 10 agents each | mp `retro` (one agent; "Tool economy", "No-ops"); cp `continual-learning` | Plan D4. |
| Slice agents re-read context | brief item 5; L118 | mp `implement-spec` ("context pointers"); poteto `feature` (one owner for code-coupled work); mp `handoff` | Plan D2 (agent groups). |

Dex and Emil: Dex `codebase-analyzer` fits no open class (L26 and L114 are already in `research`); Dex `create_handoff` overlaps plan D2. Emil's motion rules match no incident of the week.

## 2. Per workflow part

Columns: item, one line, whether ours is older in a way that matters (Older), whether a skipped item now fits (Fits).

**Analysis and research.** Ours: `research`, deliver Phase 1.

| Item | One line | Older | Fits |
|---|---|---|---|
| pstack `how`, `why`; poteto `investigation` | Explorers plus an explainer; cited read-only answer | No | No (no MCP evidence stores) |
| mp `research`; Dex `codebase-analyzer` | Our source; `file:line` only | No | No (L26, 114 already encoded) |

**Planning and unknowns.** Ours: deliver Phases 1-3, `architect`.

| Item | One line | Older | Fits |
|---|---|---|---|
| poteto `multi-phase-plan`, `check-plan.mjs`, `feature` step 3 | Settle by prototype; lint the plan; throughput checkpoint | No | In plan (D2, S5) |
| pstack `blast-radius` | One fact that makes the change safe, proven by code, levels 1-5 | No | Yes, rec 5 |
| pstack `figure-it-out` | Bespoke playbook, predicate, rigor level | No | No (deliver is that playbook) |
| mp `grilling`, `wayfinder`, `to-spec`, `to-tickets` | Design tree; fog map; spec and tickets | No | Frontier idea in plan D2; rest blocks on the user |

**Implementation and TDD.** Ours: `tdd`, deliver Phase 4.

| Item | One line | Older | Fits |
|---|---|---|---|
| pstack `tdd` | Our source; upstream removed "Do not add tests when the practical signal is weak" | No (we keep stricter text) | No |
| mp `tdd` | Seams "confirm them with the user"; tautological-test anti-pattern | No | No (blocks on the user) |
| mp `implement`, `implement-spec` | Frontier of tickets; worktree per implementer | No | No (shared `.build`, bench ban) |

**Debugging and flaky tests.** Ours: `diagnosing-bugs`, `tdd/references/flake-triage.md`, `scripts/flake-monitor/`.

| Item | One line | Older | Fits |
|---|---|---|---|
| poteto `bug-fix` | Reproduce on the same surface; binary-search the cause | No | No |
| poteto `runtime-forensics`, `trace-forensics` | Capture, reduce to the cause, map to source; paired capture | No | Partly, rec 7 |
| pstack `principle-attack-the-premise` | Premise and census before the next fix | Our one-liner drops "census as a script" | Yes, rec 6 |

**Code review.** Ours: `interrogate`, `review-panel`, 4 code lenses, 5 docs lenses, `deslop`.

| Item | One line | Older | Fits |
|---|---|---|---|
| mp `code-review` | Standards axis (Fowler smells) and Spec axis, kept apart | n/a | Spec axis, rec 3 |
| cp `thermo-nuclear-code-quality-review` | "Code judo"; 1k-line file rule | No (our lens has code judo and 400 lines) | No |
| cp `thermo-nuclear-review`, `thermos` | Security and breakage audit | n/a | No (no secrets, no flags) |
| pstack `no-comments` + `comment-sicko` | Delete comments | n/a | No (AGENTS.md wants STE comments) |
| Emil `review-animations` | Motion standards | n/a | No incident this week |

**Verification and on-screen checks.** Ours: `verify-this`, `driving-the-app.md`, `hid.swift`, `ax.swift`, `screenshot.sh`.

| Item | One line | Older | Fits |
|---|---|---|---|
| pstack `create-verification-skill` | Launch, Doctor, Drive, Evidence, Cleanup, Helpers; feature map | n/a | Yes, recs 1 and 4 |
| pstack `maintain-verification-skill` | Source wave plus one live pass per feature | n/a | Later, after rec 4 |
| poteto `visual-parity` | Baseline harness; nonzero image diff fails | n/a | Yes, rec 2 |
| cp `verify-this` | Our source; unchanged since the pin | No | No |
| cp `control-ui`, `run-smoke-tests` | Browser CDP; Playwright | n/a | No (AppKit) |

**UI design and critique.** Ours: a UI expert panel of several model families and Claude lenses, decisions 0023, 0025, 0027.

| Item | One line | Older | Fits |
|---|---|---|---|
| poteto `prototype`; mp `prototype` (UI.md) | Throwaway variants behind one switch; observe to decide | n/a | In plan D2 (prototype resolver) |
| pstack `principle-experience-first` | User delight over convenience | No | No |
| Emil skills (secondary) | Four motion gates; 300 ms | n/a | Skip now (no motion defect) |

**Reflect.** Ours: `reflect` (3 reviewers, synthesizer, seen-once), `docs/workflow/evals.md`.

| Item | One line | Older | Fits |
|---|---|---|---|
| pstack `reflect` | Our source; model slugs changed | No | No |
| mp `retro` | Navigation, checks, standards, tool economy, no-ops | No | In plan D4 |
| cp `workflow-from-chats`, `continual-learning`; pstack `recall` | Mine transcripts | No | No |
| poteto `eval` playbook | Blind candidates and a blind judge | No (we have evals.md) | No |

**Landing, git, and PR.** Ours: `pr`, `scripts/land.sh`, the guardrail hook.

| Item | One line | Older | Fits |
|---|---|---|---|
| mp `pr` | Graduated; GLOSSARY and tree-format edits | Cosmetic | No |
| mp `resolving-merge-conflicts` | Removed upstream | Yes | In plan D3 and S2 (`land.sh:30`) |
| cp `loop-on-ci`, `fix-ci`, `ci-watcher`, `review-and-ship`, `make-pr-easy-to-review` | CI loop; tidy PR | n/a | No (no `.github/workflows`) |
| poteto `shipping`, `babysit`, `opening-a-pr` | Independent verdict per PR in a stack | n/a | Idea only, in rec 3 |

**Context and subagents.** Ours: `long-runs.md`, run ledger, `advisor` tool.

| Item | One line | Older | Fits |
|---|---|---|---|
| poteto `session-pickup`, `pause-safely`; mp `handoff` | Prior trail is authoritative; resume note with pointers | No | No (Phase 0 resume covers it) |
| cp `advisor`, `orchestrate`; pstack `swarm`, `arena` | Second model; fan-out; cloud agents | No | No |

**Docs and technical writing.** Ours: `technical-writing`, `unslop`, `writing-for-agents`, `bro`. Upstream has our sources (unchanged except model slugs) and mp `wait-what` and pstack `teach` (`bro` covers both). Nothing is older; nothing new fits.

**Architecture and refactoring.** Ours: `architect`, `domain-modeling`, `docs/principles.md`.

| Item | One line | Older | Fits |
|---|---|---|---|
| mp `improve-codebase-architecture`, `codebase-design` | Hot spots from `git log`; deletion test; deep modules | n/a | Low, rec 8 |
| poteto `refactoring` playbook | Pin behavior first; subtract first; reader-load delta | No | No (principles cover it) |
| mp `domain-modeling` | CONTEXT.md renamed GLOSSARY.md | Cosmetic | No |

**Release and distribution.** Ours: `make dmg`, `make test-dmg`, decision 0026. No upstream item fits (cp `new-branch-and-pr`, `weekly-review`, `what-did-i-get-done` are status reports; nothing on DMG, signing, or Gatekeeper).

## 3. Recommendations (ranked by the class table, items not in the plan)

State on 2026-11-24: recommendation 1 landed as `scripts/verify-copy.sh` (with `verify-copy.test.sh`), and `scripts/ax.swift` reads `DIRIGIBLE_BUNDLE_ID`. Recommendations 2 to 4 are not built: no `scripts/redraw-diff.sh`, no `.claude/agents/spec-reviewer.md`, and no `.claude/skills/verify-this/features/` exist. A search with `rg` finds no text of recommendations 5 to 8 in `.claude/skills/` or `docs/workflow/`. The text below is the recommendation list of 2026-10-01.

1. **Verification: `scripts/verify-copy.sh`.** Change: one script makes the verify copy (copy, bundle ID, ad-hoc sign), builds `ax` for that ID through a `DIRIGIBLE_BUNDLE_ID` variable (on 2026-10-01 `scripts/ax.swift` hard-coded `com.delineas.dirigible`), answers a privacy prompt by button name, has a `doctor` (process up, right build, window present, screen not locked), and stops by the PID it started (then `pkill -f`, `.claude/skills/verify-this/references/driving-the-app.md`). Test file `verify-copy.test.sh`. Why: L166, 180, 190, 193, 195 and a backlog item of 2026-10-01; agents rebuilt this by hand each run. Risk: low; a tooling class with its own tests. **Adapt** (`create-verification-skill` Launch, Doctor, Helpers, Cleanup).
2. **Verification: `scripts/redraw-diff.sh`.** Change: capture after the gesture, force a full redraw of the same state, capture again, diff pixels above an alpha threshold, exit non-zero on any differing pixel. `verify-this` and the D2 look check call it. Why: the third occurrence (L82, L109, L187); it found V1 and V2. Risk: low; a forced redraw needs an app hook or a resize, so probe that first. **Adapt** (`visual-parity`).
3. **Code review: a `spec` lens.** Change: `.claude/agents/spec-reviewer.md` reads `analysis.md` and the diff and reports criteria missing or partial, behavior not asked for, and a criterion that changed in `plan.md` or `decisions.tsv` with no edit in `analysis.md`; it quotes the criterion line. It runs at the code gate, and for the diff of any Phase 7 return to Phase 4. Why: L162 and L189 (second occurrence), L192. Risk: one more agent per gate; use a cheap model. **Adapt** (`mp code-review` Spec axis).
4. **Verification: a feature map.** Change: `.claude/skills/verify-this/features/` with 5 files (record a take, live follow and scroll, mouse edits, export, start window). Each has the H2s "How to reach it", "Drive", "End state that proves it", and "Gotchas" (for example a trackpad scroll with phases, a late device start). Why: the D2 look check needs a short recipe per feature; V3 and M4 appeared only with the real gesture. Risk: medium; the map goes stale, so reflect flags a slice that changes a mapped feature. **Adapt** (`create-verification-skill` step 3).
5. **Planning: a "safe because" line.** Change: when `risk: yes`, each risky slice in `plan.md` states the one fact that makes it safe, its proof level (1 said, 2 line cited, 3 walked, 4 ran, 5 reproduced in the app), and the probe. `check-plan.sh` (S5) requires the line. Why: L43, 53, 71, 144; gates found siblings one round at a time. Risk: low. **Adapt** (`blast-radius`).
6. **Review: an attack-the-premise trigger.** Change: in `interrogate/references/lead-judgment.md`, when an Act-on item names an invariant that an earlier round already fixed, the lead writes the shared premise and its census before the next fix. Why: L16, 19, 43, 53, 191. Risk: low; text only. **Adapt** (`principle-attack-the-premise`).
7. **Performance: trace before a fix.** Change: in `deliver/references/performance-criteria.md`, a budget miss gets an `xctrace` Time Profiler capture and one hypothesis from the eight `perf-issue` families before code changes. Each attempt gets a kept or reverted row. Why: N25, P4, timeline-view C9. Risk: low. **Adapt** (`perf-issue`, `hillclimb`).
8. **Architecture: a hot-spot scan every 10 runs.** Change: a backlog goal that ranks `git log` hot spots (`Studio.swift`: 396 lines, 37 commits since 2026-09-23; `TimelineDocumentView.swift`: 385 lines, 32 commits), applies the deletion test, and writes candidates to `## Later`. No HTML report, no grilling. Why: two files are near the 400-line rule. Risk: low; no incident this week, so it ranks last. **Adapt** (`improve-codebase-architecture`).

## 4. Skip

- cp `loop-on-ci`, `fix-ci`, `ci-watcher`, `babysit`, `get-pr-comments`: no CI, no reviewers.
- cp `review-and-ship`, `new-branch-and-pr`, `fix-merge-conflicts`, `check-compiler-errors`: shorter copies of deliver Phases 6-9.
- cp `make-pr-easy-to-review`, `pr-review-canvas`: a history rewrite needs a force push.
- cp `control-ui`, `control-cli`, `run-smoke-tests`: browser, PTY, Playwright; ours drives AppKit.
- cp `thermo-nuclear-*`, `thermos`: our lenses cover them; no secrets or flags here.
- cp `weekly-review`, `what-did-i-get-done`, `workflow-from-chats`, `advisor`, `continual-learning`, `orchestrate`, `ralph-loop`, `agent-compatibility`, `cli-for-agents`; pstack `recall`, `automate-me`: reflect and the advisor tool cover them, or they need Cursor cloud.
- pstack `swarm`, `arena`, `figure-it-out`, poteto `autopilot-*`: Cursor models or parallel builds; deliver and review-panel cover them.
- pstack `no-comments`: AGENTS.md requires STE comments.
- pstack `how`, `why`, `teach`, `make-bot-ui`, dyl-stack, benny: `research` and `bro` cover them, or they are Cursor-internal.
- mp `grilling`, `grill-me`, `loop-me`, `to-questionnaire`, `triage`, `wizard`, `to-spec`, `to-tickets`, `tdd` seam confirmation: they wait on the user.
- mp `implement-spec` fan-out: shared `.build` and the bench ban.
- mp `setup-pre-commit`, `migrate-to-shoehorn`, `setup-ts-deep-modules`, `scaffold-exercises`, writing-*: TypeScript or article prose.
- Emil motion lens: no motion defect this week.

## Sources

- https://github.com/cursor/plugins (clone `2eb7ed4`; compare `b42effe...main`): `pstack/{skills,agents,docs/guide}`, `cursor-team-kit/{skills,agents}`, `thermos`, other plugins by description.
- https://github.com/mattpocock/skills (clone `d81f3a1`; compare `c55ee46...main`): `skills/engineering/*`, `skills/productivity/{handoff,wait-what}`, `skills/in-progress/loop-me`.
- `dex-emil.md` (secondary).
- Local: `AGENTS.md`, `.claude/skills/*`, `.claude/agents/*`, `docs/principles.md`, `scripts/{land.sh,ax.swift}`, the local files `.scratchpads/{learnings,ledger,backlog}.md` and `runs/*/decisions.tsv` (not in git), this run's `plan.md`, `run.md`, and the two earlier research files.
