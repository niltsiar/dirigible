---
name: research
description: Investigate a question against high-trust primary sources and capture the findings as a Markdown file in docs/research. Use when the user names a person, repo, post, URL, or skill set to check, or wants a topic, docs, or API facts researched, also during a run.
---

Spin up a **background agent** (the `Agent` tool with `run_in_background: true`) to do the research, so you keep working while it reads.

Its job:

1. Investigate the question against **primary sources** (official docs, source code, specs, first-party APIs), not a secondary write-up of them. Follow every claim back to the source that owns it. A rule that you take by analogy from a decision of this repo made for another feature (for example a scope rule of another command) has no owner source. Mark it "Inference:", list it as an open question for the plan, and name the case that it was not checked against, at least the most common gesture of the new feature. The caller does not ask a research agent for releases or scope rules: those are plan decisions.
2. Write the findings to a single Markdown file, citing each claim's source.
3. If a claim needs a probe (a small program that tests the real behavior), run it with `scripts/probe.sh <folder> <command>` (AGENTS.md, Run ledger), in the folder that the caller names. When the caller says that a monitored loop or a bench runs, run no probe, no build, and no `swift` or `make` command: they change the timing that the loop measures. Write the probe source in the findings as an open question, and the caller runs it after the loop. This step wins over any other probe step.
4. Save it as `docs/research/<topic>.md`, with a `Date: YYYY-MM-DD` line and a `## Sources` section. `make check-docs` checks both. Write it in STE (the **technical-writing** skill).
