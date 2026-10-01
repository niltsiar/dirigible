# Research: Dex Horthy (HumanLayer) and Emil Kowalski skills

Date: 2026-10-01

Method: raw files from GitHub read through WebFetch. WebFetch passes each page through a small model, so quotes marked (paraphrase) are summaries, not verbatim text. Treat them as NOT VERIFIED verbatim. File names and lists come from the GitHub contents API and are reliable. The local skills read: deliver, interrogate, research (full); others by size and name.

## 1. Dex Horthy (@dexhorthy, humanlayer/humanlayer)

Primary source: `.claude/commands/` (27 files) and `.claude/agents/` (6 files) in https://github.com/humanlayer/humanlayer.

Commands: create_plan, iterate_plan, implement_plan, validate_plan, research_codebase, create_handoff, resume_handoff, ralph_research, ralph_plan, ralph_impl, create_worktree, oneshot, oneshot_plan, local_review, commit, debug, describe_pr, founder_mode, linear. Agents: codebase-locator, codebase-analyzer, codebase-pattern-finder, thoughts-locator, thoughts-analyzer, web-search-researcher.

Findings (paraphrase unless stated):
- Research, plan, implement with "frequent intentional compaction": status is compacted into a file between phases. "A bad line of a plan could lead to hundreds of bad lines of code", so humans review the research and the plan, not the diff (ace-fca.md, paraphrase).
- `create_plan`: "Do NOT spawn sub-tasks before reading these files yourself in the main context." Then parallel locator/analyzer agents. Rule: no open questions in the final plan; "Every decision must be made before finalizing the plan". But it says "STOP. Research or ask for clarification", and it has user checkpoints (structure approval, option choice). This blocks on the user. Do not copy the checkpoints.
- Success criteria are split in two lists: Automated Verification (commands) and Manual Verification (human judgment).
- `implement_plan`: tick plan checkboxes, resume from the first unticked box, and on a mismatch print "Expected / Found / Why this matters". It pauses after each phase for manual verification. Do not copy the pause.
- `validate_plan`: report with Automated, Manual Testing Required, then Matches Plan / Deviations from Plan / Potential Issues.
- `create_handoff`: compact status; prefer `file:line` references over code snippets; list the 2-3 critical documents.
- `codebase-analyzer`: a "documentarian, not critic" agent. It lists `file:line` evidence, Entry Points, Data Flow. It does not suggest fixes. Sonnet model, read-only tools.
- `ralph_*` + `create_worktree`: pick the top small ticket, make a worktree, run an agent there, open a PR. This is a ticket loop on Linear; our deliver loop is richer.

## 2. Emil Kowalski (@emilkowalski, emilkowalski/skills)

Primary source: https://github.com/emilkowalski/skills (13 skills; install `npx skills add emilkowalski/skills`). README: "Agents don't have great taste." Scope table from the README: most skills are Web; `animate-expo` and `write-swift` are native. `apple-design` is listed as Web but its content covers Apple interaction principles.

Read:
- `review-animations`: 10 standards: justified motion, frequency-appropriate, ease-out not ease-in, UI under 300 ms, origin-aware, interruptible, GPU-only, reduced motion, asymmetric timing, cohesion. Output is a Before / After / Why table and a verdict "Default posture: flag findings. Approval is earned." (paraphrase)
- `emil-design-eng`: frequency table: "100+ times daily: No animation. Ever."; "Never animate keyboard-initiated actions"; "UI animations should stay under 300ms"; button feedback 100-160 ms; tooltips 125-200 ms; dropdowns 150-250 ms. (paraphrase)
- `find-animation-opportunities`: four gates in order: Frequency, Purpose, Speed, Function. Output lists rejected candidates with the gate that killed each. "sometimes the best animation is no animation." (paraphrase)
- `improve-animations`: audit, vet each finding, then self-contained plans by leverage (impact / effort) that "any agent can execute" (paraphrase).
- `apple-design`: springs and interruptibility, velocity handoff, press feedback on mouseDown, reduced motion (`accessibilityReduceMotion`), "avoid full-window dragging animations on macOS", menu bar and Cmd+key conventions are fixed anchors. The API example `.spring(response:dampingRatio:velocity:)` in the fetched text looks wrong for SwiftUI: NOT VERIFIED. Read the real file before use.
- `write-swift`: the fetch returned only a greeting. NOT READ. Check before any use.

## 3. Fit, by part of the workflow

| Part | Dex | Emil | Repo today |
|---|---|---|---|
| Analysis / research | `codebase-analyzer` pattern: evidence-only, `file:line`, no opinions | none | `research` skill, 13 lines, primary sources. Close. Missing: a `file:line`-only mode for in-repo reading. |
| Planning | No open questions in the plan (good); user checkpoints (bad) | none | Phase 1-2 already log defaults and probe limits. poteto-mode "probe, do not ask" (earlier doc) is a better fit. Automated/Manual split already exists in analysis (named manual checks). |
| Implement / TDD | Resume by plan checkboxes; Expected/Found/Why on a mismatch | none | Phase 4 step 4 "if the plan proves wrong, stop, update plan". Same idea. Duplicate. |
| Code review | `validate_plan` deviation report | `review-animations` strict, table form | `interrogate` has five lenses and skeptics. No lens for motion or interaction. |
| Verification / on-screen | Manual list kept separate | frequency and 300 ms budgets are checkable on screen | verify-this + `driving-the-app.md`. Has no interaction-craft checklist. Brief item 4 shows late on-screen defects. |
| UI design / panel | none | Strongest fit: the four gates and the 10 standards translate (see below) | UI panel exists only as a memory note (ui-expert-panel); decisions 0023, 0025, 0027. No written motion rules. |
| Reflect | none | none | Reflect is richer than anything here. |
| Landing | `commit`, `describe_pr`, worktrees | none | `land.sh` + `pr` skill. Duplicate. |
| Context / subagents | Intentional compaction, handoff file; read key files in the main context before spawning | none | `run.md` + `decisions.tsv` are the handoff. Subagents re-read AGENTS.md each time (brief item 5). A short per-run "context pack" is the gap. |
| Docs / writing | none | none | STE skills. No fit. |

What transfers from Emil to AppKit/SwiftUI (inference, not tested): the frequency rule (keyboard actions and transport toggles in a recorder get no animation), the 300 ms ceiling, ease-out for entering, never ease-in, interruptible motion (SwiftUI springs retarget; a restarting animation is a defect), `accessibilityReduceMotion`, press feedback on mouse-down, origin-aware popovers (anchor to the trigger; native `NSPopover` does this). What does not transfer: `transition: all`, `transform-origin`, GPU-only properties, hover media queries, CSS curves.

Fit for speed: neither author gives a speed gain that the repo lacks. Dex's compaction rule is what `run.md`, `decisions.tsv`, and `references/long-runs.md` already do. His `create_plan` blocks on the user and his `implement_plan` pauses; both are slower than ours.

## 4. Recommendations (ranked)

1. **UI motion and interaction lens for the UI panel and the on-screen check.** File: new `.claude/skills/deliver/references/ui-motion-rules.md` (about 25 lines, STE), linked from deliver Phase 2 (visible-criterion line) and from `verify-this` on-screen steps. Change: port the four gates (Frequency, Purpose, Speed, Function) and 6 transferable standards with SwiftUI/AppKit names (reduce motion, interruptible spring, ease-out, 300 ms, no animation for key-driven actions, press on mouse-down). Output form: Before / After / Why table plus a "rejected motion" list. Why: it gives the UI panel a written, falsifiable lens, and it catches defects in slices (brief item 4). Part: UI design, verification. Risk: low (text); some rules are untested on macOS, so mark each "Inference" until a screen check proves it. Not a duplicate: the repo has no motion rules.
2. **Gate "no animation unless a gate passes" into the plan of a visible slice.** File: deliver Phase 2, one line: a slice that adds motion lists its frequency and duration in `plan.md`, with the rejected candidates. Why: stops decoration before it costs code and review rounds. Part: planning, UI. Risk: low. Depends on 1.
3. **A `file:line`-only reader mode in the research skill.** File: `.claude/skills/research/SKILL.md`, add 3 lines: for in-repo questions, the agent reports entry points, data flow, and `file:line` only, with no advice. Source: `codebase-analyzer`. Why: makes analysis subagents shorter and cheaper to read, so the lead keeps context. Part: analysis, context. Risk: low. Partly duplicate: the skill already demands cited sources.
4. **Per-run context pack for slice agents.** File: `.claude/skills/deliver/references/long-runs.md` or Phase 4: the lead writes `<run>/context.md` (the goal, the 5-10 key `file:line` refs, the active decisions, the slice list with checkboxes) and each slice prompt says "read this, not analysis.md and plan.md in full". Source: `create_handoff` (file refs over copies) and Dex's "read the key files in the main context first". Why: cuts the re-reading cost of brief item 5. Part: context and subagents. Risk: medium: a stale pack misleads; the lead must refresh it after each slice. Overlaps brief item 5 (adjacent slices to one agent); do that first.
5. **Expected / Found / Why line for a plan mismatch.** File: deliver Phase 4 step 4. Change: the `decisions.tsv` row for a plan change uses that three-part text. Why: faster triage when reflect reads the log. Part: implementation, reflect. Risk: very low. Mostly a duplicate of step 4 today; low value.
6. **Deviation section in the Phase 7 verdict.** File: `run.md` template (`new-run.sh`): add "Deviations from plan" next to verdicts. Source: `validate_plan`. Why: pr.md and reflect read one place. Part: verification, landing. Risk: low. Partly duplicate (verdicts, defaults "open for the user").
7. **Reject** Dex's user checkpoints in `create_plan` and the phase pause in `implement_plan`: they block an unattended loop.
8. **Reject** `ralph_*`, `create_worktree`, `oneshot`: a Linear ticket loop. Our `land.sh`, deliver, and worktree notes cover it.

Duplicates already in the repo: 5, 6, and half of 3. New value: 1, 2, 4.

## Sources
- https://github.com/humanlayer/humanlayer/tree/main/.claude (contents API: `.claude/commands`, `.claude/agents`)
- Raw: `.claude/commands/create_plan.md`, `implement_plan.md`, `validate_plan.md`, `create_handoff.md`, `ralph_impl.md`, `.claude/agents/codebase-analyzer.md` (humanlayer/humanlayer, main), all read through a summarizing fetch (paraphrase)
- https://github.com/humanlayer/advanced-context-engineering-for-coding-agents (`ace-fca.md`, summary only)
- https://github.com/emilkowalski/skills and raw `skills/{review-animations,emil-design-eng,find-animation-opportunities,improve-animations,apple-design,write-swift}/SKILL.md` (summaries; write-swift not read)
- Local: `.claude/skills/deliver/SKILL.md`, `interrogate/SKILL.md`, `research/SKILL.md`, `.scratchpads/runs/2026-10-01-workflow-speed/brief.md`
