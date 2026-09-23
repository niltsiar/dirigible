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
Workflow({ name: "review-panel", args: { target: "plan" | "diff", intent: "<paragraph>", scope: "<plan path, or base ref such as main>" } })
```

The workflow runs these reviewer agents from `.claude/agents/` in parallel, then asks independent skeptics to refute each finding:

| Lens | Agent | Plan gate | Code gate |
|---|---|---|---|
| Premortem | `premortem` | yes | yes |
| Devil's advocate | `devils-advocate` | yes | yes |
| Architecture | `architecture-reviewer` | yes | yes |
| Correctness and code quality | `code-quality-reviewer` | no | yes |

The workflow returns `missing`: the lenses that gave no result. A gate with a missing lens is incomplete. Run the missing lens again with the Agent tool before you judge.

If the Workflow tool is not available (for example, another agent harness reads this file), spawn the same agents with the Agent tool in one message, one call per lens. Fill each prompt from `references/reviewer-prompt.md` with the intent, the target, `references/rubric.md`, and, at the code gate, `references/code-quality-review.md`.

## Step 4: Synthesize

1. Parse all surviving findings.
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
