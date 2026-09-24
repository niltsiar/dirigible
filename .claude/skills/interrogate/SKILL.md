---
name: interrogate
description: "Use for \"interrogate\", \"review panel\", \"adversarial review\", \"premortem\", \"devil's advocate\", \"challenge this\", or \"tear this apart\", and at the plan gate and the code gate of the deliver skill. Several reviewer subagents with different lenses attack a plan or a diff, then the lead judges the findings."
---

# Interrogate

Run a panel of reviewer subagents over a plan or a diff. Each reviewer has a different lens. The adversarial signal comes from lens diversity and model diversity. The deliverable is a judged verdict. Do NOT auto-apply changes inside this skill. The caller (usually the deliver skill) acts on the verdict.

## Step 1: Determine the target and the scope

- **Plan gate.** The target is a plan file, usually `.scratchpads/runs/<run>/plan.md`, plus any design sketch.
- **Code gate.** The target is the diff of the current branch: `git diff main...HEAD` plus the working tree. If the user points at files or a commit range, use that.

## Step 2: State the intent

Write one paragraph that states the intent. Derive it from the plan, the commit messages, and the task in the run ledger. If you are unsure about the intent, stop and resolve it first. Reviewers judge the execution against this paragraph.

## Step 3: Run the panel

Run the saved workflow `review-panel` with the Workflow tool:

```
Workflow({ name: "review-panel", args: { target: "plan" | "diff", intent: "<paragraph>", scope: "<plan path, or base ref such as main>", round: <n>, maxRounds: <2 for plan, 3 for diff>, prior: ["<review-*-1.md>", ...] } })
```

Pass `round` and the verdict files of the earlier rounds in `prior`. The workflow picks the mode:

| Round | Mode | Reviewers |
|---|---|---|
| 1 | open | Review the whole target. |
| middle | follow-up | Read `prior`. Do not re-raise an item that is fixed, unless the fix is wrong. |
| last (`round` = `maxRounds`) | convergence | Check only that each earlier "Act on" item is fixed correctly and consistently, and that no fix added a defect in what it changed. Report a critical defect anywhere. Nothing else. |

Each round of review finds new edge cases. An open last round widens the review and never closes the gate. The convergence round closes it.

The workflow runs these reviewer agents from `.claude/agents/` in parallel, then asks independent skeptics to refute each finding:

| Lens | Agent | Plan gate | Code gate |
|---|---|---|---|
| Premortem | `premortem` | yes | yes |
| Devil's advocate | `devils-advocate` | yes | yes |
| Architecture | `architecture-reviewer` | yes | yes |
| Correctness and code quality | `code-quality-reviewer` | no | yes |

The Workflow tool caches saved workflows by name when the session starts. If `.claude/workflows/review-panel.js` changed in this session, run it with `scriptPath: ".claude/workflows/review-panel.js"` instead of `name`.

The workflow returns `missing`: the lenses that gave no result. A gate with a missing lens is incomplete. Run the missing lens again with the Agent tool before you judge.

If the Workflow tool is not available (for example, another agent harness reads this file), spawn the same agents with the Agent tool in one message, one call per lens. Fill each prompt from `references/reviewer-prompt.md` with the intent, the target, `references/rubric.md`, and, at the code gate, `references/code-quality-review.md`.

## Step 4: Synthesize

1. Parse all surviving findings. The Workflow output file holds JSON; the verdict is under `result.panel[].survived[]`. Read it with a short `python3` script (`json.JSONDecoder().raw_decode` from the first `{`) and print only the severity, title, and suggestion. Do not read the whole file into the context.
2. Findings from two or more lenses independently are the highest signal.
3. Merge duplicates and note which lenses raised them.
4. Note disagreements. One lens that contradicts another is useful context.

## Step 5: Lead judgment

You are the lead reviewer, a pragmatic senior engineer, not a neutral aggregator. Read `references/lead-judgment.md`.

Put every finding in one bucket:

- **Act on.** Real issues for correctness, data safety, or maintainability given the actual goals. These block the gate.
- **Consider.** Legitimate points, but the cost of acting now is not clearly worth it.
- **Noted.** Valid but not actionable at this stage.
- **Dismissed.** Wrong, nitpicky, or missing context. Give the reason.

For each finding, give the lens that raised it, the bucket, and one line of rationale.

For each "Act on" item in an open or follow-up round, name the invariant that it breaks. List the sibling paths: every other path that can break the same invariant (split and place, the reader and the edits, the temporary file and the rename). The fix covers the finding and every sibling path in the same commit. Findings in the next round are usually at the edge of a fix that covered only the named path.

In the convergence round:

- Only a finding about an earlier item or a fix can be "Act on". Exception: a critical finding (data loss, crash, security) can be "Act on" wherever it is.
- The workflow puts each non-critical finding whose `priorItem` is empty or "none" in `outOfScope`, without a skeptic. Put these in `.scratchpads/backlog.md` as "Consider" items with their lens. They do not block the gate.
- After you fix its "Act on" items, the gate is closed. Do not run another round. Keep each fix to the lines the finding names, so the fix does not open a new area.
- Then run one fix check: one `general-purpose` agent with the convergence findings and the diff of the fixes (at the code gate, `git diff` of the fix commits; at the plan gate, a before and after copy of `plan.md` and `design.md`). It answers three questions for each fix. Does the fix answer its finding? Does it add a rule or behavior that no finding asked for? What new failure mode does it add, for example a shared name, path, or constant that concurrent callers collide on? Correct a wrong fix. Move an added rule out of the fix and into `.scratchpads/backlog.md`. The fix check is not a review round, so it opens no new areas.

## Output format

Write the verdict to `.scratchpads/runs/<run>/review-<gate>-<n>.md` and return it:

### Intent
> [The paragraph from step 2]

### Panel
- [lens]: [N findings raised], [N survived refutation]

### Act on
[Description, lenses, why it matters.]

### Consider
[Description, lenses, tradeoff.]

### Noted
[Brief list.]

### Dismissed
[Finding and reason.]

### Agreement map
[Where the lenses agreed or diverged, and what the pattern says.]
