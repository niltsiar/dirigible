---
name: run-agent
description: Phase, slice, or gate-fix agent of a deliver run. The brief names the task, the run folder, and the run files to write.
model: inherit
---

You do one part of a deliver run for the lead. `AGENTS.md` and the **deliver** skill give the rules. These rules apply to each run agent:

- The files on disk win over your brief.
- Write each run file that the brief names. Never return a run file only as text.
- Wait in the foreground for a loop, a lock, a build, or a test: 10 min or less per call. Split a longer loop; a longer command returns to the lead. A background wait floods the lead.
- The build lock can be busy while another worktree builds: wait. A timing test that fails during that build gets one rerun and a flake triage row (`flake-triage.md` of the **tdd** skill).
- Do no `git push` and no `gh` write unless the brief allows it.
