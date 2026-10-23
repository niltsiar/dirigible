---
name: reflect
description: Mine the session for durable learnings with one agent; log a first occurrence as seen-once, and queue a second one as an upkeep item that a workflow upkeep run applies. Use when the user says reflect, and as the last step of every deliver run.
---

# Reflect

Mine the current session for durable learnings, and queue them. A reflect run makes no commit. A workflow upkeep run applies the queued rule changes in one batch. This is how the workflow of this repo improves itself.

## Rules

Each learning gets a cause key `<ID>/<class>`, by step 1 of `references/synthesizer.md`. The reflect rules of decision 0028:

1. A first occurrence becomes one `seen-once` line on the `Lesson` page of its key, and no skill edit: `- <date> seen-once <run slug> <key>: <learning>`. Write the line to a file with the Write tool, then run `scripts/wiki.py lesson <key> --from <file>`.
2. `.claude/skills/reflect/scripts/seen.sh <key>` prints the earlier lines of a key, with the wiki page and line of each. A key match is a candidate until the synthesizer records the earlier line and the shared cause. A second occurrence becomes an upkeep item with status next: `- upkeep <key>: <proposal> (<routing>; earlier: <page:line>)`. The item file for `scripts/wiki.py add next --from <file>` has the title `upkeep <key>` on line 1, a description of 12 words or fewer on line 2, a blank line, and that line. A compiler check (a type, an access level) comes before a script, and a script before a sentence: the proposal names the first that can enforce the rule, and the prose that it deletes. A first occurrence that lost data or user input, or destroyed a file outside the repo, counts as a second one.
3. Each rule change replaces or merges text in the same section. A change to always-on text (a start file: `AGENTS.md`, `CLAUDE.md`, `.claude/CLAUDE.md`, a `.claude/rules` file with no `paths:`, or a file they import; or a `description:` line) keeps the always-on words at or below the base (`scripts/check-governance.sh`): at the cap, move a whole part to a references file and leave a one-line pointer; do not trim the words of a rule. Else the item gets status later.
4. Each rule change updates `docs/workflow/rules.tsv` in the same commit: a `new` row with the source run and the key, or a changed verdict with the run in the reason. The commit body names the source run and the earlier lesson line.
5. The lens panel reviews the diff of an upkeep run once, before the merge.
6. The next run is a workflow upkeep run (deliver) when `scripts/wiki.py list next` shows 8 or more upkeep items (it applies them all), or when an item has its third occurrence or cost a rerun or an idle hour (that item first, before any product item). When `new-run.sh` prints `consolidation due`, add one upkeep item with status next, unless the list has one: delete or merge whole stale or duplicate parts of the workflow docs (do not trim the words of a rule), then set `TOTAL` to the output of `scripts/workflow-words.sh sum`, with its `decisions.tsv` row (decision 0028).
7. A reflect run or an upkeep run removes at most one rule. A duplicate line gets a `merge` row whose target is the kept ID. A stale or no-op line gets a `delete` row whose reason gives the evidence. Skip it when no line qualifies. This is the only removal rule; other docs point here.
8. An upkeep run runs `scripts/eval/run.sh` (in the background, AGENTS.md, Commands) for each ID that `scripts/evals-for.sh --quoted <base>` prints, before and after the change. A scenario that passed before the change and fails after it reverts its change, unless it is a holdout. A changed file with no scenario gets one first, or the commit body says why none applies.

## Process

### 1. Locate the session transcript and print the cost

Transcripts are at `~/.claude/projects/<project-slug>/<session-id>.jsonl`; the slug is the repo path with each character that is not a letter or a digit replaced by `-`. Read only the transcript of this project: a glob across other project folders reads private chats from unrelated work.

```bash
slug="$(git rev-parse --show-toplevel | sed 's/[^A-Za-z0-9]/-/g')"
ls -t ~/.claude/projects/"$slug"/*.jsonl | head -3
```

Take the newest file whose first user message matches this session; if none resolves, pass a tight digest. Also pass the run ledger (`.scratchpads/runs/<run>/`). Then run `.claude/skills/reflect/scripts/cost.sh <run folder> <transcript>` and pass its output to the agent.

### 2. Mine and route with one agent

Make one `Agent` call (`general-purpose`, `opus`). Pass `references/judgment-reviewer.md` verbatim, with the transcript path or digest where marked. When `cost.sh` prints friction above 0, or subagents share an error, also pass `references/tooling-reviewer.md` and `references/divergent-reviewer.md` as lenses for the same agent. Then tell the agent to route its learnings by `references/synthesizer.md` (its output goes in `<JUDGMENT_OUTPUT>`; the other two are empty), and to run `seen.sh <key>` and `scripts/wiki.py lessons --seen-once` (each `seen-once` lesson line) for `<SEEN_OUTPUT>`. It returns the Accepted, Seen once, Rejected, and Backlog lists.

### 3. Record

- Write each Seen once item with `scripts/wiki.py lesson <key> --from <file>` by rule 1.
- Write each Accepted item with `scripts/wiki.py add next --from <file>` as an upkeep item by rule 2. An item that weakens a test gate is an item with status next for the user, not an upkeep item.
- Write each Backlog item with `scripts/wiki.py add <status> --from <file>`, with the status that the synthesizer names (`next` or `later`).
- Write each file with the Write tool. The tool removes the file after its commit.
- Log one `decisions.tsv` row (phase 8) with the counts.

### 4. Workflow upkeep run

A deliver run with the goal "apply the upkeep items". If the user asked for a checkpoint, show the items first and wait for approval. For each item:

- Follow the **writing-for-agents** skill for an edit of a skill, an agent, `AGENTS.md`, or `CODING_STANDARDS.md`.
- Edit repo files only (`.claude/skills/`, `.claude/agents/`, `.claude/workflows/`, `AGENTS.md`, `CODING_STANDARDS.md`, `docs/`, `Makefile`, `scripts/`), never user-level files under `~/.claude/`.
- Edit `.claude/hooks/` only when `make test-hooks` covers it (a chain rule through `expect_each_join`, an AppleScript rule through `expect_each_form`, a guarded file through `expect_each_write`) and keeps each block case. A rule that guards a file name or a command allows a list of read forms, each with an allow case, and blocks all other forms.
- Make one commit per changed doc file, with its `rules.tsv` rows and the check that replaces its prose.
- Write a lesson line with the date, the key, and the commit hash (`scripts/wiki.py lesson <key> --from <file>`), and move the item to done (`scripts/wiki.py move <id> done`).

Then, once for the batch: the eval pass of rule 8, and the `review-panel` workflow on the diff (`target: "diff"`, `maxRounds: 2`, and the `risk`, the doc lenses, and `paths` of Step 3 of the **interrogate** skill, also in a small run). Each Act on finding gets a fix commit or a revert commit before the merge.

### 5. Summarize

Write the agent count of the reflect run in the Result cell of a new row of the run, `| <run> | <goal> | open | <count> |`, with `scripts/wiki.py log --from <file>` (the last row of a run wins). Put the summary in the pull request body. Short list, no preamble:

- Edits applied (upkeep run only): `<path>`: the change in words, one line each.
- Upkeep items and backlog: one line each, in words, with no cause key.
- Dropped: one line per rejected finding and its reason.
