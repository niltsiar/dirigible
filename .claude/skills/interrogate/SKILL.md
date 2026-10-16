---
name: interrogate
description: "Use for \"interrogate\", \"review panel\", \"adversarial review\", \"premortem\", \"devil's advocate\", \"challenge this\", or \"tear this apart\", and at the plan gate and the code gate of the deliver skill. Reviewer subagents with different lenses attack a plan or a diff, and the lead judges the findings."
---

# Interrogate

Run a panel of reviewer subagents over a plan or a diff. Each reviewer has a different lens. The deliverable is a judged verdict. The caller (usually the deliver skill) acts on it. This skill applies no fix.

## Step 1: Determine the target

- **Plan gate:** the plan file, usually `<main-checkout>/.scratchpads/runs/<run>/plan.md`, plus any design sketch.
- **Code gate:** `git diff main...HEAD` plus the working tree, or the files or commit range that the user names.

## Step 2: State the intent and the settled list

Write one intent paragraph from the plan, the commit messages, and the task in the run ledger. Reviewers judge the execution against it. If the intent is unclear, stop and resolve it first. Pass the `## Unknowns` table of `analysis.md` with it. An Act-on finding that shows a missing unknown gets a new row in that table and a `decisions.tsv` row with the result `missed unknown`.

Then list the settled choices, one line each: the scope, the run order, the choices that the user asked for, and the tradeoffs that `decisions.tsv` accepted with a reason. A line about behavior or scope ("no vertical scroll this run") is also a claim about the code: name its holder (a test or a file:line), or pass it as a claim to check. A tradeoff is settled only in the form "we accept X in exchange for Y". A tradeoff that loses user input, or departs from the reference apps (`AGENTS.md`), is settled only when the user approved it. Else pass it as a claim to check. When a skeptic refutes a finding against such a line, put the finding in `## Next` of `.scratchpads/backlog.md` as a user decision, not in Dismissed.

## Step 3: Run the panel

Run the saved workflow `review-panel` with the Workflow tool:

```
Workflow({ name: "review-panel", args: { target: "plan" | "diff", intent, scope: "<plan path or base ref>", round, maxRounds, prior: [...], settled: [...], ledger: "<main-checkout>/.scratchpads/runs/<run>/decisions.tsv", risk, lenses?, paths?, worktree: "<absolute worktree path>" } })
```

The workflow runs the reviewer agents in parallel. Skeptics try to refute each warning and critical finding. A small run passes the `lenses` of the **deliver** class table in one call. Else, with no `lenses`, each gate runs `.claude/agents/premortem.md`, `devils-advocate`, and `architecture-reviewer`. A `risk: yes` code gate makes one call per item below that the classes from `scripts/check-changed.sh` match:

- sources, sources-risk: the default lenses.
- `AGENTS.md`, `CODING_STANDARDS.md`, `.claude/skills`, `.claude/agents`, `docs/workflow`: `lenses: ["context-engineering", "prompt-engineering", "harness-engineering", "eval-engineering", "compound-engineering"]`, with those paths in `paths`.
- other docs paths: no panel.

A `risk: yes` code gate with a non-docs, non-comments class also calls the `code-review` skill in round 1 only, while `git status --porcelain` of the branch tree is empty and no `mutate.py` control is active:

- Round 1: `high` on `origin/main...<branch>`.
- A result that names no range file did not run: rerun it once on `origin/main...<branch>`.
- No skeptic: the fixer checks each finding.
- Round 2 is the convergence workflow, with no `code-review`.

Take `maxRounds` from the **deliver** class table and `risk` from `scripts/check-changed.sh`. An error for an empty lens selection, or a diff with no changed file, is not a clean review: correct the arguments (a branch in a worktree needs `worktree`).

Pass `round`, and the earlier verdict files in `prior`.

The Workflow tool caches saved workflows at session start: after a change to `.claude/workflows/review-panel.js` in this session or on the branch, pass `scriptPath` with its absolute path in the tree under review, instead of `name`.

A lens in `missing` (no result, or no `checked` list) makes the gate incomplete, because an empty result looks the same as "no findings". Run that lens again with the Agent tool before you judge.

Read `references/reviewer-prompt.md` when the Workflow tool is not available: it builds each agent prompt with `references/rubric.md` and `references/code-quality-review.md`.

## Step 4: Synthesize

1. Read the Workflow output file (JSON) with a short `python3` script (`json.JSONDecoder().raw_decode` from the first `{`). Print only the severity, title, and suggestion of `result.panel[].survived[]`, of `result.panel[].refuted[]` with `skeptic.reason`, and of `result.panel[].nits[]`. Keep the whole file out of the context.
2. Findings from two or more lenses independently are the highest signal.
3. Merge duplicates and note which lenses raised them.
4. Note disagreements: one lens that contradicts another is useful context.

## Step 5: Lead judgment

You are the lead reviewer, a pragmatic senior engineer, not a neutral aggregator. Read `references/lead-judgment.md` when you judge the findings and when you close a gate: it holds the filters, the Invariant and Siblings fields, the rounds, and the fix check.

Put every finding in one bucket, with its lens and one line of rationale:

- **Act on:** real issues for correctness, data safety, or maintainability, given the actual goals. These block the gate.
- **Consider:** legitimate, but acting now is not clearly worth the cost.
- **Noted:** valid, but not actionable now.
- **Dismissed:** wrong, nitpicky, or missing context. Give the reason.

## Output format

Write the verdict to `.scratchpads/runs/<run>/review-<gate>-<n>.md` and return it, with these sections, each under a `##` heading:

- **Intent:** the paragraph from step 2.
- **Panel:** for each lens, the findings raised and the findings that survived.
- **Act on:** a numbered list. Each item starts with `(<severity>, <lenses>)`, then the description, why it matters, Invariant, and Siblings.
- **Consider:** description, lenses, tradeoff.
- **Noted:** a brief list.
- **Dismissed:** each finding with its reason, each refuted finding with the skeptic reason, and each nit of `nits` that is not a Consider item. Read each reason: overrule a skeptic that refuted a real premise.
- **Agreement map:** where the lenses agreed or diverged, and what the pattern says.

Then run `scripts/check-plan.sh <run folder>`. It must exit 0 before the fixer starts.
