---
name: reflect
description: Mine the session for durable learnings with one agent; log a first occurrence as seen-once, and queue a second one as an upkeep item that a workflow upkeep run applies. Use when the user says reflect, and as the last step of every deliver run.
---

# Reflect

Mine the current session for durable learnings, and queue them. A reflect run makes no commit. A workflow upkeep run applies the queued rule changes in one batch. This is how the workflow of this repo improves itself.

## Rules

Each learning gets a cause key `<ID>/<class>`, by step 1 of `references/synthesizer.md`. The reflect rules of decision 0028:

1. A first occurrence becomes one `seen-once` line in `.scratchpads/learnings.md`, and no skill edit: `- <date> seen-once <run slug> <key>: <learning>`.
2. `.claude/skills/reflect/scripts/seen.sh <key>` prints the earlier lines of a key. A key match is a candidate until the synthesizer records the earlier line and the shared cause. A second occurrence becomes an upkeep item in `## Next` of the backlog: `- upkeep <key>: <proposal> (<routing>; earlier: <file:line>)`. A compiler check (a type, an access level) comes before a script, and a script before a sentence: the proposal names the first that can enforce the rule, and the prose that it deletes. A first occurrence that lost data or user input, or destroyed a file outside the repo, counts as a second one.
3. Each rule change replaces or merges text in the same section, within the row of its file in `docs/workflow/budgets.tsv`. Else the item goes to `## Later` of the backlog. A row goes up only in a commit that names a `decisions.tsv` row.
4. Each rule change updates `docs/workflow/rules.tsv` in the same commit: a `new` row with the source run and the key, or a changed verdict with the run in the reason. The commit body names the source run and the earlier learnings line.
5. The lens panel reviews the diff of an upkeep run once, before the merge.
6. When `## Next` has 3 or more upkeep items, the next run is a workflow upkeep run (deliver), which applies them all.
7. A reflect run or an upkeep run removes at most one rule. A duplicate line gets a `merge` row whose target is the kept ID. A stale or no-op line gets a `delete` row whose reason gives the evidence. Skip it when no line qualifies. This is the only removal rule; other docs point here.
8. An upkeep run runs once, for the batch, each scenario that `scripts/evals-for.sh --quoted <base>` prints, before and after the change. A scenario that passed before the change and fails after it reverts its change. A changed file with no scenario gets one first, or the commit body says why none applies.

## Process

### 1. Locate the session transcript and print the cost

Transcripts are at `~/.claude/projects/<project-slug>/<session-id>.jsonl`; the slug is the repo path with each character that is not a letter or a digit replaced by `-`. Read only the transcript of this project: a glob across other project folders reads private chats from unrelated work.

```bash
slug="$(git rev-parse --show-toplevel | sed 's/[^A-Za-z0-9]/-/g')"
ls -t ~/.claude/projects/"$slug"/*.jsonl | head -3
```

Take the newest file whose first user message matches this session; if none resolves, pass a tight digest. Also pass the run ledger (`.scratchpads/runs/<run>/`): it records decisions and review verdicts. Then run `.claude/skills/reflect/scripts/cost.sh <run folder> <transcript>` and pass its output to the agent.

### 2. Mine and route with one agent

Make one `Agent` call (`general-purpose`, `opus`). Pass `references/judgment-reviewer.md` verbatim, with the transcript path or digest where marked. When `cost.sh` prints friction above 0, also pass `references/tooling-reviewer.md` and `references/divergent-reviewer.md` as more lenses for the same agent. Then tell the agent to route its own learnings by `references/synthesizer.md` (its output goes in `<JUDGMENT_OUTPUT>`; the other two outputs are empty), and to run `seen.sh <key>` and `grep -n seen-once .scratchpads/learnings.md` for `<SEEN_OUTPUT>`. It returns the Accepted, Seen once, Rejected, and Backlog lists.

### 3. Record

- Append each Seen once item to `learnings.md` by rule 1.
- Append each Accepted item to `## Next` as an upkeep item by rule 2. An item that weakens a test gate goes to `## Next` for the user, not as an upkeep item.
- Append each Backlog item to `.scratchpads/backlog.md`, in the section that the synthesizer names.
- Log one `decisions.tsv` row (phase 8) with the counts. Make no commit.

### 4. Workflow upkeep run

A deliver run with the goal "apply the upkeep items". If the user asked for a checkpoint, show the items first and wait for approval. For each item:

- Follow the **writing-for-agents** skill for an edit of a skill, an agent, or `AGENTS.md`.
- Edit repo files only (`.claude/skills/`, `.claude/agents/`, `.claude/workflows/`, `AGENTS.md`, `docs/`, `Makefile`, `scripts/`), never user-level files under `~/.claude/`.
- Edit `.claude/hooks/` only when `make test-hooks` covers the change (a chain rule through `expect_each_join`) and keeps each block case.
- Make one commit per changed doc file, with its `rules.tsv` rows and the check that replaces its prose.
- Append a `learnings.md` line with the date, the key, and the commit hash, and remove the item from `## Next`.

Then, once for the batch: the eval pass of rule 8, and the `review-panel` workflow on the diff (`target: "diff"`, `maxRounds: 2`, the five doc lenses and `paths` of Step 3 of the **interrogate** skill, also in a small run). Each Act on finding gets a fix commit or a revert commit before the merge.

### 5. Summarize

Write the agent count of the reflect run in the Result cell of the run line in `.scratchpads/ledger.md`. Put the summary in the pull request body. Short list, no preamble:

- Edits applied (upkeep run only): `<path>`: the change in words, one line each.
- Upkeep items and backlog: one line each, in words, with no cause key.
- Dropped: one line per rejected finding and its reason.
