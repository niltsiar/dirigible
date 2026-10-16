# Model routing

The model and effort of each job of a deliver run. Read this file before each `Agent` or `delegate_task` call that starts a phase, slice, gate-fix, or check job. The evidence is in run `2026-10-16-agent-setup`: its usage report and its free-model bench.

## Usage limits

Before the call, read `~/.claude/usage/limits.json` on the lead thread: an in-process subagent does not update it. Use the `five_hour` row. A `resetsAt` in the past starts a new window: count it as 0 %. With no file, the mode is normal.

| Mode | When | Change |
|---|---|---|
| save | `percentUsed` is 75 or more | A code-reading question for a plan goes to space-bunny-free first, with a Claude fallback. Each new `run-agent` takes effort `medium` in place of `high`, except a `risk: yes` slice. A typed agent keeps its frontmatter. |
| spend | the reset is 60 min or less away, and `percentUsed` is 70 or less | Start the queued Opus jobs first. A `risk: no` slice can take Opus. |
| normal | all other values | The tables below. |

At the highest rate on record (54 % to 81 % in about 70 min of Opus work), 25 % lasts about one hour.

## Claude jobs

- A typed agent (`.claude/agents/*.md`) takes the model and effort of its frontmatter. `review-panel.js` sets the effort of a lens.
- Analysis, plan, architect, and a `risk: yes` slice: Opus, effort `high`.
- A `risk: no` slice: Sonnet, effort `high`.
- Start one implementer agent for each group of the `Agents:` line, not one agent for all of Phase 4. It writes a handoff in `run.md` when it stops. Replies with more than 150k tokens of context were 60 % of the cost.
- A small run keeps its one agent for Phases 1-2 and 4 (deliver class table).

## Free jobs

Free jobs run on the free models of OpenCode Zen. They are optional extras: a free result never replaces a Claude step.

Only four free models keep no input and do not train on it: glm-5.3-flash-free, deepseek-v4.1-flash-free, space-bunny-free, and longcat-2.5-preview-free. Only these models get a free job. Each OpenCode session in the repo sends `AGENTS.md` and the skill list to the model, so no other model can run in the repo.

| Job | Model | Use |
|---|---|---|
| Extra review lens at a gate | space-bunny-free, then deepseek-v4.1-flash-free | Beside the Claude lenses |
| Translation check | space-bunny-free | The Claude check runs on a skip |
| First read of a red push-check log | space-bunny-free | The lead reads the log on a skip |
| Second opinion on the panel findings | glm-5.3-flash-free | Beside the skeptic |

Explore, the implementer, and the skeptic stay on Claude.

Only the lead thread has `delegate_task`. With no such tool, skip the free job. Call it with `mode: "async"`, `role: "review"`, `target: { providerInstanceId: "opencode", model: "opencode/<model>", options: { variant: "high" } }`, and a `title` that is unique in the run. The OpenCode session gets that title.

1. The gate never waits for a free job. When the Claude steps are done, judge with the results that are in.
2. On "Rate limit exceeded", skip the job and log a `decisions.tsv` row with the result `skipped: rate limit`. Zen publishes no cap for the account, but about 25 sessions in one afternoon reached it. Keep bench and trial sessions off gate days.
3. The brief names the only `.scratchpads/` files that the model can read, and its answer file. `AGENTS.md` sends a model to the ledger and the backlog, and a bench model read an earlier review (the answer key) when it could.
4. Before you judge a free result, run `.claude/skills/interrogate/scripts/free-lens-reads.sh "<title>" <allowed file>...`. A non-zero exit voids the result: log it, and judge without it.
