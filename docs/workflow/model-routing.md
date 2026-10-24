# Model routing

The model and effort of each job of a deliver run. Read this file before each `Agent` or `delegate_task` call that starts a phase, slice, gate-fix, or check job. The evidence is in run `2026-10-16-agent-setup`: its usage report and its free-model bench.

## Usage limits

The hook `.claude/hooks/usage-hook.sh` gives the usage mode as context at each `Agent`, `Workflow`, `SendMessage`, and `delegate_task` start. With no usage-mode line in the tool context, run `.claude/skills/deliver/scripts/usage-mode.sh` before the call. The script reads `~/.claude/usage/limits.json`, holds the thresholds, and prints the mode. The file is optional: Claude Code does not write it, and a Claude Code mod of the user setup (a turn hook) writes it after each main-agent turn. With no file, the mode is `normal`. A non-zero exit is `normal`.

| Mode | Change |
|---|---|
| stop | Start no new job, except a free-model job, the reflect agent, and a job that the user approved past the stop. Stop at a safe point and write the handoff. |
| save | A code-reading question for a plan goes to space-bunny-free first. On no result, a Claude agent takes it. Each new `run-agent` takes effort `medium` in place of `high`, except a `risk: yes` slice. A typed agent keeps its frontmatter. |
| spend | Start the queued Opus jobs first. A `risk: no` slice can take Opus. |
| normal | The tables below. |

## Claude jobs

- A typed agent (`.claude/agents/*.md`) takes the model and effort of its frontmatter. `review-panel.js` sets the effort of a lens.
- Analysis, plan, architect, and a `risk: yes` slice: Opus, effort `high`.
- A `risk: no` slice: Sonnet, effort `high`.
- Start one implementer agent for each group of the `Agents:` line, not one agent for all of Phase 4. It writes a handoff in `run.md` when it stops. Replies with more than 150k tokens of context were 60 % of the cost. An agent stops after 90 active minutes: `.claude/hooks/agent-clock.sh` refuses its other tool calls. An agent that reaches its last commit after about 60 active minutes writes the handoff and hands back, and the lead runs the group-end check. An agent is over the 150k line when its context is over 150k, or when the sum of `duration_ms` over all its notifications is over 75 min (wall time is an upper bound of active time). Then the lead starts a new agent of the slice model in place of a resume.
- A small run has one subagent for Phases 1-2 and one for Phase 4 after the plan gate (deliver class table).
- After the last code gate fix, one closing agent runs Phase 7 up to `scripts/check-governance.sh`, then Phase 8 and the PR text, with the model of a slice. On the light path (the light path bullet of Checks by change class in deliver), no closing agent starts: the Phase 7 agent runs Phase 7, and the lead runs Phase 8 and the PR text (deliver Phase 7). The cold reader of the PR text is a separate Sonnet agent. The push check and the land run in the lead.

## Free jobs

Free jobs run on the free models of OpenCode Zen and on the Antigravity models of T3. They are optional extras. A job has no result when it hits the rate limit, returns an error, has its isolation refused, its audit fails, it has no answer when the Claude steps end, or the lead has no `delegate_task`. A row says if its Claude step runs always, or only on no result.

Any free model can get repo text and train on it: the project goes open source (user, 2026-10-16). The Antigravity models take the same rule. No credential, personal data, or real-voice recording goes to a model.

| Job | Model | Claude step | Use |
|---|---|---|---|
| Extra review lens at a gate | space-bunny-free, then deepseek-v4.1-flash-free | always | Beside the Claude lenses |
| Extra review lens at a gate | antigravity/gemini-4-argon | always | Beside space-bunny-free and the Claude lenses |
| Translation check | muse-spark-1.3-contributor-free, then antigravity/gemini-3.8-flash | no result | A result replaces the Claude check |
| First read of a red push-check log | muse-spark-1.3-contributor-free, then antigravity/gemini-3.8-flash | no result | A result replaces the first read of the lead |
| Second opinion on the panel findings | muse-spark-1.3-contributor-free | always | Beside the skeptic |
| Extra cold reader | antigravity/gemini-3.8-flash | always | Beside the Sonnet cold reader |

Explore, the implementer, and the skeptic stay on Claude.

Only the lead thread has `delegate_task`. With no such tool, the job has no result. Call it with `mode: "async"`, `role: "review"`, `isolation: "worktree"`, `target: { providerInstanceId: "opencode", model: "opencode/<model>", options: { variant: "high" } }`, and a new `title` of the form `<run>/<gate>/<lens>`. The OpenCode session gets that title. The call returns no session id. An Antigravity job has the target `{ providerInstanceId: "antigravity", model: "<id>" }` with no options. Read its child thread with `t3_thread_read`, `view: "activity"`, and `maxCharsPerItem` 50000, and save the whole output with the Write tool to `<run>/logs/<lens>-activity.json`.

1. The gate never waits for a free job. When the Claude steps are done, judge with the results that are in: a job with no answer has no result.
2. On "Rate limit exceeded", an error, or a refused isolation, the job has no result: log a `decisions.tsv` row with the result `skipped: rate limit` or `skipped: <the error>`. Zen publishes no cap for the account, but about 25 sessions in one afternoon reached it. Keep bench and trial sessions off gate days. The Antigravity quota is unknown, so each such failure of an Antigravity call is no result, never a reason to wait.
3. The `worktree` isolation gives the session its own checkout with an empty `.scratchpads/`. Put the brief in the task text: the model reads the run diff with `git diff origin/main...<branch>`, and returns its answer as the task result. Name in the brief the only paths that it can read. `AGENTS.md` sends a model to the ledger and the backlog, and a bench model read an earlier review (the answer key) when it could.
4. Before you judge a free result, run `.claude/skills/interrogate/scripts/free-lens-reads.sh <run>/<gate>/<lens> <allowed file>...`. It finds the session by its title: exactly one row has it (else exit 2), and its directory is not the main checkout (the worktree is under `~/.t3/worktrees/<repo>/`). A non-zero exit voids the result, which is no result: log it, and judge without it. The header of the script lists each failure. For an Antigravity job, run `.claude/skills/interrogate/scripts/free-lens-reads.sh --t3 <run>/logs/<lens>-activity.json <allowed file>...` in place of the title form. After you judge the result, remove the child worktree and branch of the thread: run `git status --porcelain` in the worktree, then `git worktree remove <path>` and `git branch -d <branch>`.
