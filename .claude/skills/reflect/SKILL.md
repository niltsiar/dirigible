---
name: reflect
description: Mine the session for durable learnings with reviewer subagents; log a first occurrence as seen-once, and turn a second one into a skill, AGENTS.md, or check edit. Use when the user says reflect, and as the last step of every deliver run.
---

# Reflect

Mine the current session for durable learnings, then route them into edits. This skill is how the workflow of this repo improves itself.

## Rules

Each learning gets a cause key `<ID>/<class>`, by step 1 of `references/synthesizer.md`. The reflect rules of decision 0028:

1. A first occurrence becomes one `seen-once` line in `.scratchpads/learnings.md`, and no skill edit: `- <date> seen-once <run slug> <key>: <learning>`.
2. `.claude/skills/reflect/scripts/seen.sh <key>` prints the earlier lines of a key. A key match is a candidate until the synthesizer records the earlier line and the shared cause. A second occurrence changes a skill, `AGENTS.md`, or a check. A check or script comes before a sentence: when a lint rule, script, test, hook, or `Makefile` target can enforce the rule, change the proposal to that mechanism, and delete the prose that it replaces. A first occurrence that lost data or user input, or destroyed a file outside the repo, counts as a second one (reason in the commit body).
3. Each rule change replaces or merges text in the same section, within the row of its file in `docs/workflow/budgets.tsv`. Else the item goes to `## Later` of the backlog. A row goes up only in a commit that names a `decisions.tsv` row.
4. Each rule change updates `docs/workflow/rules.tsv` in the same commit: a `new` row with the source run and the key, or a changed verdict with the run in the reason. The commit body names the run and the earlier learnings line.
5. Each rule change goes through the lens panel: it reviews the diff of the reflect commits once per run, before the merge (step 5).
6. Each reflect commit runs `make check-changed`, joined to `git commit` with `&&`.
7. A reflect run removes at most one rule. A duplicate line gets a `merge` row whose target is the kept ID. A stale or no-op line gets a `delete` row whose reason gives the evidence. Skip it when no line qualifies. This is the only removal rule; other docs point here.
8. When a change trims, deletes, merges, or moves a rule, run each scenario of `docs/workflow/evals.md` whose `files` column names a changed file. A scenario that passed before the change and fails after it reverts the change. A changed file with no scenario gets one first, or the commit body says why none applies.

## Process

### 1. Locate the session transcript and print the cost

Transcripts are at `~/.claude/projects/<project-slug>/<session-id>.jsonl`; the slug is the repo path with each character that is not a letter or a digit replaced by `-`. Read only the transcript of this project: a glob across other project folders reads private chats from unrelated work.

```bash
slug="$(git rev-parse --show-toplevel | sed 's/[^A-Za-z0-9]/-/g')"
ls -t ~/.claude/projects/"$slug"/*.jsonl | head -3
```

Take the newest file whose first user message matches this session; if none resolves, pass a tight digest. Also pass the run ledger (`.scratchpads/runs/<run>/`): it records decisions and review verdicts. Then run `.claude/skills/reflect/scripts/cost.sh <run folder> <transcript>`, also for a run with no friction, and pass its output to the reviewers.

### 2. Spawn the reviewers

When `cost.sh` prints `friction: 0`, make one `Agent` call with `references/judgment-reviewer.md`. Else, in one message, make three `Agent` calls (`general-purpose`), one per template: `references/judgment-reviewer.md` (`opus`), `references/tooling-reviewer.md` (`sonnet`), and `references/divergent-reviewer.md` (`opus`). Different models give different angles. Pass each template verbatim, with the transcript path or digest where marked.

### 3. Synthesize

Run `.claude/skills/reflect/scripts/seen.sh <key>` for each key, and `grep -n seen-once .scratchpads/learnings.md`. Read `references/synthesizer.md` when you start the synthesis: pass it verbatim to one `Agent` call (`general-purpose`, `opus`), with the reviewer outputs and that output where marked. It returns the Accepted, Seen once, Rejected, and Backlog lists.

### 4. Apply

The workflow improves itself without a human in the loop, because each change is a commit that a human can read and revert. If the user asked for a checkpoint, show the Accepted list first and wait for approval.

- Follow the **writing-for-agents** skill for an edit of a skill, an agent, or `AGENTS.md`.
- Edit repo files only (`.claude/skills/`, `.claude/agents/`, `.claude/workflows/`, `AGENTS.md`, `docs/`, `Makefile`, `scripts/`), never user-level files under `~/.claude/`.
- Edit `.claude/hooks/` only when `make test-hooks` covers the change and no existing block case is removed or changed to allow.
- Commit on the run branch: one commit per changed doc file per run, with its `rules.tsv` rows and the check that replaces its prose. The body names the session moment that caused it. With no Accepted item, log `no learnings` in `decisions.tsv` and make no commit.
- Do not apply an edit that weakens a test gate. Put it in `## Next` of the backlog for the user.
- Append each Backlog item to `.scratchpads/backlog.md`, in the section that the synthesizer names.
- Append each Seen once item to `learnings.md` by rule 1, and a line with the date, the key, and the commit hash for each applied learning.

### 5. Review the reflect diff

Do this once, after the last reflect commit and before the merge, when the run made a commit.

1. Run `make check-changed BASE=<base>`, where `<base>` is the parent of the first reflect commit. Its `classes:` line picks the lenses.
2. Run the `review-panel` workflow on that diff (`target: "diff"`, `scope: "<base>"`, `maxRounds: 2`), with the lenses and `paths` of Step 3 of the **interrogate** skill. Pass `scriptPath` when `review-panel.js` changed in this session.
3. Judge round 1 and run the fix check. Each Act on finding gets a fix commit or a revert commit before the merge.

### 6. Summarize

Write the agent count of the reflect run (reviewers, synthesizer, panel) in the Result cell of the run line in `.scratchpads/ledger.md`. Put the summary in the pull request body, so the user reviews each reflect commit. Short list, no preamble:

- Edits applied: `<path>` and commit hash, one line each.
- Backlog: one line each.
- Dropped: one line per rejected finding and its reason.
