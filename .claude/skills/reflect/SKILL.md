---
name: reflect
description: Mine the session for durable learnings with three parallel reviewer subagents, then route each learning to a concrete edit on a repo skill, AGENTS.md, or a structural check. Use when the user says reflect, and as the last step of every deliver run.
---

# Reflect

Mine the current session for durable learnings, then route them into edits. This skill is how the workflow of this repo improves itself.

## When to invoke

Invoke when the user says "reflect" or "/reflect", and at the end of every deliver run. Skip when the session was trivial or when every step followed an existing skill without friction. One-offs are not learnings.

## Process

### 1. Locate the session transcript

Claude Code stores transcripts at `~/.claude/projects/<project-slug>/<session-id>.jsonl`. The project slug is the absolute repo path with every character that is not a letter or a digit replaced by `-`. Only read the transcript of this project. Do not glob across other project folders. That reads private chats from unrelated work.

```bash
slug="$(git rev-parse --show-toplevel | sed 's/[^A-Za-z0-9]/-/g')"
ls -t ~/.claude/projects/"$slug"/*.jsonl | head -3
```

Take the newest file whose first user message matches this session. If no path resolves, write a tight digest of the session and pass that instead. Also pass the run ledger (`.scratchpads/runs/<run>/`), which records decisions and review verdicts.

### 2. Spawn three reviewers in parallel

One message, three `Agent` calls with `subagent_type: general-purpose`. Use different models where possible to get different angles.

| Lens | `model` | Prompt template |
|---|---|---|
| Judgment | `opus` | `references/judgment-reviewer.md` |
| Tooling | `sonnet` | `references/tooling-reviewer.md` |
| Divergent | `opus` | `references/divergent-reviewer.md` |

Pass each template verbatim, with the transcript path or digest where marked. Reviewers return findings in their final message.

### 3. Synthesize

One `Agent` call, `subagent_type: general-purpose`, `model: opus`. Use `references/synthesizer.md` verbatim, with each reviewer's full output inlined where marked. The synthesizer returns an Accepted, Rejected, and Backlog list.

### 4. Structural enforcement check

For each Accepted item that a lint rule, script, test, or `Makefile` target would enforce more reliably, change the proposal to that mechanism. See the **encode-lessons-in-structure** principle in `docs/principles.md`. A mechanism beats a sentence.

### 5. Apply

This repo allows the workflow to improve itself without a human in the loop, because every change is a git commit that a human can read and revert.

- Follow the **writing-for-agents** skill when an edit touches a skill, an agent, or `AGENTS.md`.
- Apply each Accepted edit to repo files only: `.claude/skills/`, `.claude/agents/`, `.claude/workflows/`, `AGENTS.md`, `docs/`, `Makefile`, `scripts/`. Never edit user-level files under `~/.claude/`.
- Edit `.claude/hooks/` only when `make test-hooks` covers the change and no existing block case is removed or changed to allow. When one class of hook false positive is in `learnings.md` twice, fix the hook with a test case. Do not add another workaround line.
- Commit each learning as its own commit, for example `docs(skills): tdd requires tolerance on DSP asserts`. The body says which session moment caused it.
- Do not apply an edit that deletes a rule from `AGENTS.md` or weakens a test gate. Put it in the backlog for the user.
- Append Backlog items to `.scratchpads/backlog.md`.
- Append one line per applied learning to `.scratchpads/learnings.md` with the date and the commit hash.

If the user is present and asked for a checkpoint, show the Accepted list first and wait for approval.

### 6. Summarize

Short list, no preamble:

- Edits applied: `<path>` and commit hash, one line each.
- Backlog: one line each.
- Dropped: one line per rejected finding and its reason.
