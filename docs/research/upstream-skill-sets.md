# Upstream skill sets: what changed and what we skipped

Date: 2026-10-01

Outcome: run `2026-10-01-workflow-speed` adopted recommendation 1 (parallel and serial groups in the plan, and the reversing word of a default), recommendation 3 (the `resolving-merge-conflicts` skill is deleted), and recommendation 5 (`scripts/check-plan.sh`). The run rejected recommendation 2, because a one-round plan gate found two critical items in a small tooling run. The run rejected recommendation 4, because the repo has no CI checks to wait on.

Method: `gh api` on the GitHub repos (a compare of our pinned commit with `main`, and reads of raw files). The tweet of 2026-09-29 came from a mirror (fxtwitter). Items that we did not read in full have the mark NOT VERIFIED.

## Our skills come from two upstream repos

The source of truth is `.claude/skills/THIRD_PARTY.md`, plus the git commits e8ee556, 1e069af, 9bb6139, and e32d803. All the sources have the MIT license.

| Local item | Origin | Pinned commit |
|---|---|---|
| architect, bro, interrogate, reflect, tdd, technical-writing, unslop | `cursor/plugins` `pstack/skills/*` (Lauren Tan, who is "poteto") | b42effe, 2026-09-23 |
| deslop, verify-this | `cursor/plugins` `cursor-team-kit/skills/*` | b42effe |
| docs/principles.md (shortened) | `pstack/skills/principle-*` | b42effe |
| diagnosing-bugs, domain-modeling, pr, research, resolving-merge-conflicts (deleted on 2026-10-01), writing-for-agents, `.claude/hooks/git-guardrails.sh` | `mattpocock/skills` | c55ee46, 2026-09-18 |
| deliver, review-panel, and the five lens reviewers | Local. Not from upstream. | |

Finding: the "poteto" skills are in `cursor/plugins` as the `pstack` plugin. The repos of poteto himself have no skill set. His repos `how`, `noodle`, and `brainmaxxing` are older, and `how` is already in pstack. Thus the poteto set and the cursor set are one repo. The Pocock set is a separate repo.

## cursor/plugins (pstack and cursor-team-kit)

URL: https://github.com/cursor/plugins. The repo has 56 commits since our pin, and 122 files changed.

### The updates since our copy do not matter for us

The seven pstack skills that we copied changed by 1 to 9 lines each, for the handling of model slugs.

- reflect: the reviewer models now come from a `pstack-models.mdc` rule, "Leave `model` unset when the value is `auto` or `inherit-parent`".
- interrogate and architect: the same fallback text for the model.
- tdd: upstream removed the line "Do not add tests when the practical signal is weak". Upstream also made the "if impractical" step softer: "Use the closest executable regression check instead".
- principle-prove-it-works lost 9 lines. principle-never-block-on-the-human lost 2 lines. We did not read these changes as a diff (NOT VERIFIED what upstream cut).

Action: none. Our adapted copies already replaced the Cursor model slugs.

### The new plugins and the plugins we did not copy are not relevant

- `dyl-stack` (a new plugin): dyl-mode, dyl-review, dyl-ready-pr, build-figma, and principle-the-algorithm. They are for Figma and for Cursor-internal work. Not relevant. NOT read in full.
- `advisor`, `continual-learning`, `ralph-loop`, `orchestrate`, and `thermos` are plugins. We already have an `advisor` tool and our own reflect. The Ralph loop sends the same prompt again until a `<promise>` tag appears. Our deliver loop does more.

### Some items that we skipped now fit

1. The Autonomy rule of `poteto-mode` is the best fit. Quote: "About to `AskQuestion` on a 'which approach'... fork -> classify it before you ask. If the answer is a fact you could observe by running something... it is not the human's to answer. Sketch it via the Prototype playbook and let the result decide." Also: "Under a full-autonomy grant, decide a call that the grant covers, act on it, and report it... Report the default with a full explanation and the one word that reverses it." This rule is the "planning that removes all unknowns without blocking on the user" rule. Our deliver has "choose a default, log it". It does not have a rule for plans that says "probe the fact, do not ask". We do have "an untried limit is a guess. Probe".
   URL: https://github.com/cursor/plugins/blob/main/pstack/skills/poteto-mode/SKILL.md
2. `poteto-mode/playbooks/feature.md` step 3 is a "throughput checkpoint" with four items: the blocking first steps, the independent workstreams, the shared mutable state, and the "smallest safe decomposition. If one worker is best, name why." It also says: "Code-coupled work (one feature, one migration) goes to a single owner... Parent-level fan-out is for slices that produce independent artifacts." This item fits the speed problem. It makes the plan name what runs in parallel and what must wait. Our plan.md has slices, but no line for parallel and serial work.
3. `playbooks/multi-phase-plan.md` step 2: "Settle open questions by prototype before you write... Ask the operator only about a product or preference call that no run can settle." Step 6 adds a script (`check-plan.mjs`) that lints the plan file. We could lint plan.md for the required lines (risk:, the first test, and the negative control). NOT VERIFIED how much of check-plan.mjs applies.
4. `principle-sequence-verifiable-units`, `never-block-on-the-human`, and `laziness-protocol`: we already carry all three in docs/principles.md.
5. `swarm` (parallel workers, one report) needs the Cursor cloud. Our `Agent` tool and `review-panel` cover it. The rule worth taking: "Drop a result that does not record the SHAs and method its brief names." The value for us is low.
6. `blast-radius`: "Find the one fact it's safe because of... prove it by running code." This item fits checks that scale with risk. It replaces a long list of risks with one proved fact. It could give input to the `risk:` decision (0028). The value is medium. It does not make the runs faster.
7. `cursor-team-kit/loop-on-ci`, `fix-ci`, and `review-and-ship` use `gh pr checks --watch --fail-fast`. They say "Inspect current PR checks before waiting" and "retry once and report flake evidence". Our `scripts/land.sh` already does this. Review-and-ship is a shorter version of deliver Phases 6 to 9. We do not need it.
8. `show-me-your-work` keeps a TSV decision log with `ts, phase, decision, why, evidence, result`. This log is our `decisions.tsv` (the same format). We already have it. Its rule of a `start` row for a new run could help a run that resumes. The gain is small.
9. `recall` and `workflow-from-chats` mine transcripts. Our reflect does that.
10. `no-comments` removes the comments before a review. AGENTS.md says that code comments are in STE. Skip it.

## mattpocock/skills

URL: https://github.com/mattpocock/skills. The repo has 21 commits since our pin.

### Upstream removed resolving-merge-conflicts

- `pr` moved from `in-progress` to `engineering` (it graduated). The content change is small (+6 and -4 lines). We keep our copy.
- `domain-modeling`: upstream renamed `CONTEXT.md` to `GLOSSARY.md` (a rename across 12 lines). Our copy says `CONTEXT.md`, and we adapted it already. This change is optional.
- Upstream removed `resolving-merge-conflicts`. Quote from the changeset: "It's no longer needed, and nothing replaces it: the agent works through an in-progress merge or rebase conflict without a dedicated skill." Deliver Phase 9 step 3 calls this skill. Option: delete the skill and the call. The context saving is small.

### Two new skills match what we have or run slices in parallel

- `retro` (graduated from in-progress) is for "suggesting improvements to the coding agent's environment". Its categories are navigation, automated checks, and coding standards. Its rule: "a mechanical [violation] gets a deterministic check... Default to building the check over writing the rule." This rule matches our reflect and `encode-lessons-in-structure`. We have it. We read only the first 2200 characters. The rest is NOT VERIFIED.
- `implement-spec` (graduated) keeps a task graph with a "frontier" of ready tickets. Implementer subagents work, each in a worktree. "Communication to and from subagents should be sparse... through context pointers". The subagents run "in the background where possible for maximum concurrency". The skill then merges each branch into an integration branch.

### The skipped items fit only in part

- The `implement-spec` pattern: slices with no dependency run in parallel worktrees. Our deliver runs the slices in series. The speed gain is real only if the slices are independent. Our slices share `Sources/` modules and a build lock (`swift build` in the same `.build`). AGENTS.md also forbids heavy builds in parallel with benches. The risk is medium, and the gain is medium. Not first.
- `grill-me`, `to-spec`, `to-tickets`, and `triage` are interactive and block on the user. They do not fit an unattended loop. We did not read them. We judged them from the name and the description (NOT VERIFIED).

## The Matt Pocock post names three skill authors and gives no workflow advice

The mirror is api.fxtwitter.com. Post 2105022638368403658, 2026-09-29, 7.4k likes. Full text: "My top 3 skill makers: @poteto, @dexhorthy, @emilkowalski. Always learn a ton from reading their skills." The post has no link, no article, and no quote post.

The post names three people and gives no workflow advice. Relevance: it confirms that poteto (pstack) is a good source, and we already use it. `@dexhorthy` (Dex Horthy, HumanLayer, "context engineering", "research / plan / implement") and `@emilkowalski` (UI animation skills) are two more names. The skills of Dex could fit planning that removes unknowns. I did not fetch them (NOT VERIFIED that they exist as a public repo). The skills of Emil fit only the UI polish.

## The repo already has most of the rules, and the gap is time

This section uses the three research docs and the deliver and reflect skills. We did not read them again in full. Deliver already has these items: defaults that it logs and does not ask, checks that scale with the class (decision 0028), gates of one round for the low-risk classes, `scripts/land.sh`, and a `long-runs.md`. Reflect has a panel of five lenses. The gap is in the time to plan and in the wall-clock time, not in the rules about when to ask.

## Recommendations, ranked by speed gain and safety

1. Add a "probe, do not ask" line and a line for parallel and serial work to Phase 2 of `.claude/skills/deliver/SKILL.md`. The change: in `plan.md`, add the line "Unknowns: each is a fact observed by a probe (log the probe) or a logged default; none waits for the user". Also add the line "Parallel: which slices touch disjoint files; which wait on a build". Source: the poteto-mode Autonomy rule and the throughput checkpoint. Why: the change removes the unknowns before the plan gate, so the gate does not send the plan back. Safety: the change is text only and removes no check. It gives the highest value for each word.
2. Skip the review panel of the plan gate for the `docs` and `tooling` classes when the plan has one slice. The change: the class table in deliver Phase 2 gets a "plan gate: none" cell for those rows, with a note in the log. Why: the change removes a full panel (3 agents) from the many small runs. Source: poteto-mode "Casual turn... don't", and multi-phase-plan step 1: "When the change is one or two files with an obvious approach, skip the plan." It is safe if the code gate stays. It needs the decision of the user, because decision 0028 sets the rounds.
3. (Done on 2026-10-01: `.claude/skills/` has no `resolving-merge-conflicts`.) Delete the `resolving-merge-conflicts` skill and its call in deliver Phase 9 step 3. The change: delete `.claude/skills/resolving-merge-conflicts/`, edit the line, and update THIRD_PARTY.md. Why: upstream removed the skill because it is not necessary. Less text loads, and nothing is lost. The gain is small, and the safety is high.
4. Use `gh pr checks --watch --fail-fast` in `scripts/land.sh`, or run its waits in the background with a Monitor. Then the loop starts the next run while the PR checks run. Source: cursor-team-kit/loop-on-ci. Why: the change removes the idle wait. Risk: the next run must not start on a dirty tree, so it needs a worktree. NOT VERIFIED what land.sh does now. Check it first.
5. Add a plan linter (`scripts/check-plan.sh`) that fails when `plan.md` does not have the `risk:` line, a first test for each slice, or the Unknowns line. Source: pstack `check-plan.mjs`. Why: a check replaces a review comment that repeats (`encode-lessons-in-structure`). The gain is indirect (fewer gate rounds). The cost: a script and a `.test.sh` that `make check` runs.

Not recommended: do not copy `swarm`, `orchestrate`, `ralph-loop`, or the parallel worktrees of `implement-spec` now. They need cloud agents or a parallel build tree, and the project forbids parallel heavy builds during bench loops.

## Sources

- https://github.com/cursor/plugins (compare `b42effe...main`, `pstack/skills/*`, `cursor-team-kit/skills/*`, `advisor`, `continual-learning`, `ralph-loop`, and `orchestrate`)
- https://github.com/cursor/plugins/blob/main/pstack/skills/poteto-mode/SKILL.md and `playbooks/feature.md`, `playbooks/multi-phase-plan.md`, and `playbooks/autopilot-full.md`
- https://github.com/mattpocock/skills (compare `c55ee46...main`, `skills/engineering/retro`, `implement-spec`, and the changeset `remove-resolving-merge-conflicts.md`)
- https://github.com/poteto?tab=repositories (the repo list through the API)
- Mirror: https://api.fxtwitter.com/mattpocockuk/status/2105022638368403658 (the original is https://x.com/mattpocockuk/status/2105022638368403658, not fetched directly)
- Local: `.claude/skills/THIRD_PARTY.md`, `.claude/skills/deliver/SKILL.md`, `.claude/skills/reflect/SKILL.md`, `docs/principles.md`, and the git commits e8ee556, 1e069af, 9bb6139, and e32d803
