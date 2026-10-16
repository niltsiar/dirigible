# Model routing

The model and effort of each job of a deliver run. Read this file before each `Agent` or `delegate_task` call that starts a phase, slice, gate-fix, or check job. The evidence is in run `2026-10-16-agent-setup`: its usage report and its free-model bench.

## Usage limits

Before the call, run `.claude/skills/deliver/scripts/usage-mode.sh` on the lead thread. It reads `~/.claude/usage/limits.json`, holds the thresholds, and prints the mode.

| Mode | Change |
|---|---|
| save | A code-reading question for a plan goes to space-bunny-free first. On no result, a Claude agent takes it. Each new `run-agent` takes effort `medium` in place of `high`, except a `risk: yes` slice. A typed agent keeps its frontmatter. |
| spend | Start the queued Opus jobs first. A `risk: no` slice can take Opus. |
| normal | The tables below. |

## Claude jobs

- A typed agent (`.claude/agents/*.md`) takes the model and effort of its frontmatter. `review-panel.js` sets the effort of a lens.
- Analysis, plan, architect, and a `risk: yes` slice: Opus, effort `high`.
- A `risk: no` slice: Sonnet, effort `high`.
- Start one implementer agent for each group of the `Agents:` line, not one agent for all of Phase 4. It writes a handoff in `run.md` when it stops. Replies with more than 150k tokens of context were 60 % of the cost.
- A small run keeps its one agent for Phases 1-2 and 4 (deliver class table).

## Free jobs

Free jobs run on the free models of OpenCode Zen. They are optional extras. A job has no result when it hits the rate limit, its audit fails, it has no answer when the Claude steps end, or the lead has no `delegate_task`. A row says if its Claude step runs always, or only on no result.

Any free model can get repo text and train on it: the project goes open source (user, 2026-10-16). No credential, personal data, or real-voice recording goes to a model.

| Job | Model | Claude step | Use |
|---|---|---|---|
| Extra review lens at a gate | space-bunny-free, then deepseek-v4.1-flash-free | always | Beside the Claude lenses |
| Translation check | muse-spark-1.3-contributor-free | no result | A result replaces the Claude check |
| First read of a red push-check log | muse-spark-1.3-contributor-free | no result | A result replaces the first read of the lead |
| Second opinion on the panel findings | muse-spark-1.3-contributor-free | always | Beside the skeptic |

Explore, the implementer, and the skeptic stay on Claude.

Only the lead thread has `delegate_task`. With no such tool, the job has no result. Call it with `mode: "async"`, `role: "review"`, `target: { providerInstanceId: "opencode", model: "opencode/<model>", options: { variant: "high" } }`, and a `title` of the form `<run>/<gate>/<lens>`. The OpenCode session gets that title. Keep the session id that the call returns.

1. The gate never waits for a free job. When the Claude steps are done, judge with the results that are in: a job with no answer has no result.
2. On "Rate limit exceeded", the job has no result: log a `decisions.tsv` row with the result `skipped: rate limit`. Zen publishes no cap for the account, but about 25 sessions in one afternoon reached it. Keep bench and trial sessions off gate days.
3. Start each free session in the run worktree, not in the main checkout: the call shares the checkout of the lead thread, so call it from the worktree. Its `.scratchpads/` is empty. Copy the brief files into it, and name them and the answer file in the brief: they are the only paths that the model can read. `AGENTS.md` sends a model to the ledger and the backlog, and a bench model read an earlier review (the answer key) when it could.
4. Before you judge a free result, run `.claude/skills/interrogate/scripts/free-lens-reads.sh <session id> <allowed file>...`. It audits that one session. With the title in its place, run it in the run worktree: it audits the one session that has that title in that folder, and exits 2 for two. The audit also fails a session that starts in the main checkout, a path of the main checkout, `rg -uu`, `rg --no-ignore`, `rg --hidden` with a root path, and `grep -r` with no path. A non-zero exit voids the result, which is no result: log it, and judge without it.
