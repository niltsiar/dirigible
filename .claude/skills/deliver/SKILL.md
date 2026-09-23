---
name: deliver
description: "End-to-end flow for any feature, requirement, or bug in this repo: analyze, plan, review the plan, implement test-first in atomic commits, review the code, verify, reflect, and land, with a run ledger in .scratchpads/. Use for /deliver, 'implement R3', 'build the next feature', 'plan and implement', or any autonomous run."
---

# Deliver

One run takes one goal from request to landed commits on `main`. A goal is a requirement (`R3`), a slice of one, or a bug. Every step writes to the run ledger, so a human or the next agent can see what happened and why.

Open a todo list with the phases below before you start. Do not skip a phase. A phase can be short when the goal is small, but it must leave its artifact.

## Autonomy rules

- Do not block on the human for reversible work. Choose a sensible default, record it in `decisions.tsv`, and continue. The human corrects it later.
- Stop and ask only for irreversible or outward-facing actions: deleting user data, publishing anything, rewriting `main` history.
- When a check needs hardware you cannot drive (a second audio interface, a permission prompt), write the manual check in `run.md` under "Manual checks" and continue with the closest automated check.
- Keep the main context small. Send bulk reading and research to subagents. Keep their conclusions, not their raw output.

## Phase 0: Open the run

1. Read `.scratchpads/learnings.md`, `.scratchpads/backlog.md`, and `.scratchpads/ledger.md`.
2. Look for unfinished work: `git status --porcelain`, `git branch`, and any run with status `open` in the ledger. If a run is open, resume it: switch to its branch, read its `run.md` and `decisions.tsv`, and continue at the first unchecked phase. Do not switch to `main` with uncommitted changes.
3. For a new goal, run `.claude/skills/deliver/scripts/new-run.sh <slug>`. It creates `.scratchpads/runs/<date>-<slug>/` with `run.md` and `decisions.tsv`, and adds a line to `.scratchpads/ledger.md`. For a slug that already has a run, it returns the existing folder.
4. For a new goal, make sure `main` is green: `git switch main && make check`. If it is red, fixing it is the goal of this run.
5. Create the branch now, before any file changes: `git switch -c <type>/<slug>`, for example `feat/multitrack-capture`. Write it in `run.md`. Every commit of the run, including decision records and reflect learnings, goes on this branch.

## Phase 1: Analyze

Write `analysis.md` in the run folder:

- The requirement IDs from `docs/requirements/brief.md` that this run covers.
- How Hindenburg PRO behaves for this feature. Use a subagent with web search to research it. Cite the sources.
- Acceptance criteria as falsifiable statements. Each criterion names how a test or command proves it. Example: "A 10 s recording from two devices gives two WAV files of 10 s ± 20 ms and one session XML with two `<track>` elements."
- Assumptions and open questions. Answer each question with a default and record it in `decisions.tsv`.
- What is out of scope for this run. Put the rest in `.scratchpads/backlog.md`.

## Phase 2: Plan

Write `plan.md`:

- Split the goal into vertical slices. Each slice ends in a state you can check: a test that passes and a commit. Put the riskiest unknown first.
- For each slice: the test you write first, the modules you touch, and the commit message you expect.
- If a slice sets a one-way decision (a file format, a module boundary, a threading model, a new dependency), run the **architect** skill for it and write a decision record in `docs/decisions/`.

## Phase 3: Plan gate

Run the **interrogate** skill with target `plan`. It runs the `review-panel` workflow (premortem, devil's advocate, architecture) and gives a judged verdict.

- Change the plan for every "Act on" item. Record each change in `decisions.tsv`.
- If the verdict had a critical item, run the gate again. At most two rounds. After that, record the open risk in `run.md` and continue.

## Phase 4: Implement

1. For each slice, follow the **tdd** skill: failing test, smallest change, `make check`, commit.
2. One commit is one logical change. Use Conventional Commits (see `AGENTS.md`). Never commit a red `make check`.
3. After each slice, add a row to `decisions.tsv` and tick the slice in `run.md`.
4. If the plan proves wrong, stop, update `plan.md`, and record why. Do not bolt workarounds onto a wrong plan.

## Phase 5: Clean up

Run the **deslop** skill on the branch. Run `make check`. Commit the cleanup on its own.

## Phase 6: Code gate

Run the **interrogate** skill with target `diff`. It runs the `review-panel` workflow (premortem, devil's advocate, architecture, code quality).

- Fix every "Act on" item with its own commit. A bug fix gets a regression test first.
- Put "Consider" items you do not do now in `.scratchpads/backlog.md` with the reason.
- If the verdict had a critical item, run the gate again after the fixes. At most three rounds.

## Phase 7: Verify

Run the **verify-this** skill for each acceptance criterion from Phase 1 against the real artifact: the built app, the real files, measured levels. Record each verdict (`VERIFIED`, `NOT VERIFIED`, `INCONCLUSIVE`) in `run.md`. A `NOT VERIFIED` criterion sends you back to Phase 4.

## Phase 8: Reflect

Run the **reflect** skill on the branch. It turns durable learnings into commits on skills, agents, `AGENTS.md`, or checks. Run `make check` after its commits. When the run had no friction, reflect records "no learnings" in `decisions.tsv` and makes no commit.

## Phase 9: Land and close

1. `git rebase main` on the branch, then `make check`.
2. `git switch main && git merge --ff-only <branch>`, then `git branch -d <branch>`.
3. History on `main` stays linear. Never force-push or rewrite `main`. Never commit on `main` directly.
4. In `run.md`, set the status to `done`, and write a summary: what landed (commit range), what is verified, manual checks for the human, and open risks.
5. Update the run line in `.scratchpads/ledger.md`.

## Long autonomous runs

To work through several goals, repeat the phases for the next goal from `.scratchpads/backlog.md` or the order agreed in the first planning run. Close each run before you open the next one. Every run lands on `main` green, so the human can stop the loop at any time and find a working app.

## Write everything in STE

Plans, ledger rows, review verdicts, and commit messages follow the **technical-writing** and **unslop** skills: short sentences, active voice, one idea per sentence, one word for one thing.
