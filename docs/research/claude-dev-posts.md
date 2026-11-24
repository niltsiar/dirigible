# Research: two claude.dev posts mapped to the workflow-speed run

Date: 2026-10-01

Both pages were fetched with curl (HTTP 200) and read in full, at the URLs given. Nothing here is from a search summary.

## Post 1: Automating eval design and hillclimbing with Claude

URL: https://claude.dev/blog/automating-eval-design-and-hillclimbing/ (Lance Martin, Sep 28, 2026)

### Eval design

- Four elements: tasks mirror production; "More capable models and higher effort levels typically should perform better"; headroom ("The most capable model at the highest effort should be well below 100%"); low run-to-run variance.
- Task quality test: "A good task is one where two domain experts would reach the same verdict and everything the grader checks is stated in the task." A task that "fails every evaluation run, regardless of the number of replicates" is a tell of an impossible or ambiguous task.
- Hidden state leak: "leftover state from an earlier trial (a file, a git history) can hand the agent the answer."
- Adversarial sampling: "If you pick cases because today's model fails them, you are sampling the valleys of one model's capability surface." Rule: "be able to say why a task is hard before you include it." Source order: production transcripts, bug reports and tickets, 5 to 10 hand-written cases, synthesized cases. Also: "don't blindly trust user traffic" (it skews easy).
- Grader: cheapest that fits. Programmatic when output is constrained. LLM judge otherwise, with "a rubric written as checkable claims (not a 1-to-5 scale)". With a baseline: "the judge instead reads both inputs in random order, without being told which is the baseline". The judge "should not be the model you are testing."
- Validate the grader: "it is important to read a sample of scored transcripts before believing your evaluator". Diagnostics: run the grader twice on the same output; check plumbing (timeouts, cut-off answers); headroom warning at about 95% or higher.

### Hillclimbing

- Pick a surface that is cheap to change, attributable, and well scoped. "Many internal efforts and customers have focused hillclimbing on text, such as prompts and skills." Cost is a strong objective: "even if an evaluation is saturated, you can ask Claude to find ways to reduce cost while keeping performance at parity."
- Overfitting controls: "Split the cases. Use a train set that the hillclimber may read and a test set that is never seen." "Never paste failures into the prompt." "Keep the answers structurally out of the model's reach."
- Loop: "Claude checks that the eval's noise ... is smaller than the smallest improvement you'd act on". Each round: one change as a patch, aimed at "the root ... rather than rewording a line". "if the train set improves but the test set is flat, Claude suspects overfitting and reverts the patch. If there is a regression, Claude reverts."
- Stop rule: "When the score stalls for two or three rounds, Claude reads each remaining train failure and sorts it by cause." This round makes no edit. It finds ambiguous cases, harness errors, or variance. "Tasks that never improved ... are tells that the example or grader is flawed."
- Final: "If the gain is within noise, it says so and recommends against merging." Example: 44 tickets, 30 search, 14 held out; the held-out score confirmed the gain (90.5% against 78.6%).

## Post 2: How we made claude.ai 3x faster in two weeks

URL: https://claude.dev/blog/how-we-made-claude-ai-faster/ (Raymond Wang, Sam Attard, Issac G., Sep 23, 2026)

### Where time goes, and priorities

- They picked journeys by usage data: "four journeys that make up 95% of user activity". Baselines: instrumentation "until they were directly comparable: each started with a user interaction, ended once the result was rendered".
- Prioritizing: "about twenty hand-picked projects ... Claude estimated the impact of each project in milliseconds, and we aggregated those estimates to set our targets". Refresh when done: "what have we not explored, what can we hill climb on".
- Central lesson: "With Claude, measuring something makes it tractable ... the highest-leverage thing we could do was find more things to measure."
- Findings came from counting: hook census, style recalc counts, post-paint traces, idle-tab profiles. The slow parts were duplicated work (one ID resolved three times, a leftover reload, identical snapshots cloned twice a minute).

### Verifying a gain

- Lab metric first, to avoid waiting for field data: "we looked for other ways to measure performance in the lab". Wall-clock is "too flaky to use as a CI gate", so use deterministic counts.
- Every benchmark must prove itself: "we'll unship the benches for any candidates that cannot prove that" hill climbing it gives wall-clock wins. Result: -48% instructions gave -78% wall-clock.
- Ratchet: "any PR that raised the instruction counts of those paths failed CI, and a daily job lowered each ceiling".
- Fail-before, pass-after: the layout test "went red 20 of 20 runs on main, and green 20 of 20 on the PR."
- Field check after deploy: "If performance improved, Claude locked in the win by ratcheting the benchmark down; if not, it turned the flag off and iterated."
- Honest reporting: "2-3 runs per value" is stated on a chart.

### Process

- Narrow threads with one owner: "We kept each thread deliberately narrow". Humans steer by ambition ("be braver"), taste, and direction (close threads at diminishing returns; "2ms per send is not worth the complexity").
- Guardrails first: "unit tests always came before optimizations"; flags for user-visible change; "performance wins decay", so each win got a guard.

## Mapping to this repo

### (a) Eval of workflow docs and reflect

State on 2026-11-24: the column "Repo on 2026-10-01" is the state before the workflow-speed run. The stall rule landed in `docs/workflow/evals.md` (recommendation 3), so the gap "No stop rule" is closed.

| Post method | Repo on 2026-10-01 | Gap |
|---|---|---|
| Train/test split; test never seen | Holdouts H1-H13; plan says fix agents do not read the H key points | Matches. `evals.md` says a fix that reads them "burns the holdouts"; the rule is sound. |
| Baseline judged blind, random order | Blind grader, neutral labels, frozen main baseline (plan DC4) | Matches. |
| Validate grader: read scored samples; run grader twice | One blind grader per scenario | No grader-repeat check. Grader noise is not measured. |
| Noise below the smallest gain you act on | 3 runs per scenario; "two or more passes below" rule | Never stated as a noise estimate. E8 went 2 of 3, 3 of 3; E10 1 of 3, 0 of 3: noise of this size is unmeasured. |
| Stall rule: sort failures by cause, no edit | Fix cycles 1 and 2 kept editing; E10 stayed 0 of 3 after cycle 2 | No stop rule. Cycle 2 should have been a diagnosis round: the key point may be unreachable in the answer format, not a doc defect. |
| Void tasks (all runs fail) are a tell | H1, H13 void | Matches. |
| Adversarial sampling needs a human reason | E scenarios come from incidents (L-lines) | Matches. Add a "why hard" cell. |
| Hidden state leaks | Answer agents read docs on disk in a detached worktree | Check: the worktree must not hold run folders or `.scratchpads` (a local folder, not in git). |
| Reflect: fail-before, pass-after | Rule 8 runs old scenarios after a change; seen-once before a rule | Rule 8 only guards against regression. A rule change has no scenario that fails on the old docs and passes on the new ones (except policy scenarios). |

### (b) Run speed

| Post method | Repo today | Gap |
|---|---|---|
| Measure first, per journey, comparable | `cost.sh` (S6) from `decisions.tsv` timestamps | Matches. Missing: one baseline row per phase so a later run compares. |
| Estimate each project in ms, aggregate to a target | Brief lists 10 items with hand estimates (about 9 h run) | Items have no minutes estimate or target. Verify cannot say "gain achieved". |
| Prove the metric tracks the real thing | Plan compares `cost.sh` output with `analysis.md` table | Matches (one run only). |
| Ratchet | None | No guard against the duplicate checks coming back. |
| Remove duplicated work (same ID looked up 3 times) | Stamps, bench once, replay subset | This is the core of the posts. Good fit. |
| Narrow threads, then stop at diminishing returns | One agent per slice re-reads all docs (item 5) | Same cost: each slice re-reads context. |
| Do not idle | Item 9 | Matches. |

## Recommendations (at most 6)

State on 2026-11-24: recommendation 3 is built (the stall rule is in `docs/workflow/evals.md`).
1. Ratchet test for the stamp (in this run). File: `scripts/check-plan.test.sh` or the S2 land test. Change: a test that runs `check-changed` then `land.sh` on the same tree and asserts that the full suite runs once (count of `swift test` calls in a fake `make`). Why: a "ratchet" in the posts is a CI guard that keeps a win. Without it the duplicate comes back silently. Risk: low; a fake `make` is enough.
2. Time estimate per brief item (in this run). File: `plan.md` and `run.md` (a column `est min saved`), summed to a target. Check at Phase 7: `cost.sh` of this run against the live-take-view baseline (about 9 h). Why: "Claude estimated the impact of each project in milliseconds". Risk: the estimates are guesses; mark them so. One run cannot verify gain; say INCONCLUSIVE with n=1 rather than VERIFIED.
3. Stall rule for the doc eval (in this run, one sentence). File: `docs/workflow/evals.md`, section "How the eval runs". Change: after two fix cycles with a scenario still below its rule, the next round makes no doc edit; it sorts each failing answer by cause (doc missing, doc not quoted, key point unreachable, scenario or grader flawed). Why: the post's stall rule; E10 is the live case. Risk: low; it replaces nothing, so check the budget row of `evals.md`.
4. Grader repeat (in this run, cheap). File: the Eval section of `plan.md` (not a doc). Change: run the blind grader twice on the E8-E10 packets and log whether any verdict differs. Why: "runs the grader twice on the same output". Without it a 2 of 3 vs 3 of 3 change may be grader noise. Risk: one extra agent per scenario; do it for the three policy scenarios only.
5. Fail-before for reflect rule changes (next run). File: `.claude/skills/reflect/SKILL.md` rule 8 and `docs/workflow/evals.md`. Change: a rule that reflect adds or changes needs one scenario that fails on the parent commit and passes on the tip (a policy scenario), recorded in the `rules.tsv` row. Why: the layout test "red 20 of 20 on main, green 20 of 20 on the PR". Risk: more scenarios to maintain; cap by the existing rule of one rule removal per run and the budget table.
6. Noise estimate and "why hard" column (next run). File: `docs/workflow/evals.md`. Change: record the pass-rate spread of the unchanged old docs across runs (the A/A pair, as in `bench-pairs.sh`) and the smallest pass-count change that counts; add a one-line "why hard" per scenario. Why: "noise ... is smaller than the smallest improvement you'd act on". Risk: costs about 3 extra agent runs on main; do it once.

## Not verified

- I did not check whether the answer worktree at 5b01f78 holds `.scratchpads` (the plan says detached worktree, no build; `.scratchpads` is gitignored so it should be absent).
- The posts' numbers are the authors' claims; no independent check.
- I did not read the full `analysis.md` (39 KB) or the other research files.

## Sources

- https://claude.dev/blog/automating-eval-design-and-hillclimbing/
- https://claude.dev/blog/how-we-made-claude-ai-faster/
- Repo: `AGENTS.md`, `.claude/skills/reflect/SKILL.md`, `docs/workflow/evals.md`, and the brief and `plan.md` of a local run folder (not in git)
