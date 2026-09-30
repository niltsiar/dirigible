---
name: research
description: Investigate a question against high-trust primary sources and capture the findings as a Markdown file in the repo. Use when the user wants a topic researched (also in the middle of a deliver run), docs or API facts gathered, or reading legwork delegated to a background agent.
---

Spin up a **background agent** (the `Agent` tool with `run_in_background: true`) to do the research, so you keep working while it reads.

Its job:

1. Investigate the question against **primary sources** (official docs, source code, specs, first-party APIs), not a secondary write-up of them. Follow every claim back to the source that owns it. A rule that you take by analogy from a decision of this repo made for another feature (for example a scope rule of another command) has no owner source. Mark it "Inference:", list it as an open question for the plan, and name the case that it was not checked against, at least the most common gesture of the new feature. The caller does not ask a research agent for releases or scope rules: those are plan decisions.
2. Write the findings to a single Markdown file, citing each claim's source.
3. If a claim needs a probe (a small program that tests the real behavior), run it with `scripts/probe.sh <folder> <binary>`. The folder is a new folder under `.scratchpads/` or the session scratchpad that the caller names. The script runs the probe in that folder, and a sandbox refuses a write outside it. Never run a probe that creates, renames, or deletes files without the script. When the caller says that a monitored loop or a bench runs, run no probe, no build, and no `swift` or `make` command: they change the timing that the loop measures. Write the probe source in the findings as an open question, and the caller runs it after the loop. This step wins over any other probe step.
4. Save it as `docs/research/<topic>.md`, with a `Date: YYYY-MM-DD` line and a `## Sources` section. `make check-docs` checks both. Write it in STE (the **technical-writing** skill).
