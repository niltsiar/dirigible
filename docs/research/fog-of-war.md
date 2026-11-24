# Fog of war: Matt Pocock planning skills against deliver Phases 1 to 3

Date: 2026-10-01

Outcome: run `2026-10-01-workflow-speed` adopted the Unknowns table in deliver Phase 1 (recommendation 1), the `prototype` resolver and an early look check (recommendation 2), and the missing-unknown question of the premortem lens (recommendation 3).

Scope: the planning skills of `mattpocock/skills`, compared with Phases 1 to 3 of the `deliver` skill. The findings come from the raw SKILL.md files and the docs pages. The commit is not pinned. The text is the `main` branch on 2026-10-01.

## Findings: grilling walks a design tree, and wayfinder charts the fog

The repo has these skills: `skills/productivity/grilling`, `grill-me`, `skills/engineering/grill-with-docs`, `wayfinder`, `to-spec`, `to-tickets`, `prototype`, `research`, and `to-questionnaire`.

### Grilling asks the whole frontier in rounds and leaves the decisions to the user

`grilling` is the core skill that the model calls. `grill-me` and `grill-with-docs` only call it.

- "Map this as a **design tree**: every decision branches into the decisions that hang off it."
- Work in rounds. "The **frontier** is every decision whose prerequisites are already settled." Ask the whole frontier in each round. Give each question a number and "your recommended answer". Then wait.
- "Finding _facts_ is your job, never the user's ... dispatch a sub-agent to find it." Do not block on the sub-agent. Only the downstream questions wait.
- "The _decisions_ are the user's." The docs say: "An agent running `grilling` that answers its own decisions has broken the skill."
- The end: "the frontier is empty: every branch of the design tree visited, nothing left silently assumed." Then wait for the user to confirm.
- The output is the conversation only. The skill writes no file.

`grill-me` is one line that calls `grilling`. Use it outside a working directory.

`grill-with-docs` is `grilling` plus `domain-modeling`. Its output is a glossary and ADRs that it writes as the terms resolve. This repo already has `domain-modeling` (a copy), but it does not have the grill loop.

### Wayfinder keeps the map incomplete on purpose

`wayfinder` is the "fog of war" skill (https://github.com/mattpocock/skills/blob/main/skills/engineering/wayfinder/SKILL.md). It is for work that is too big for one session. The output is a map (one tracker issue) with these sections: Destination, Notes, Decisions so far, **Not yet specified**, and Out of scope. The child tickets are decision questions. Each ticket fits one session of 100K tokens. Each ticket has one of these types:

- research (AFK: a subagent runs the research skill)
- prototype (HITL)
- grilling (HITL)
- task (manual work that unblocks a decision)

Quotes: "The map is _deliberately_ incomplete: don't chart what you can't yet see." "**Fog or ticket?** The test is whether you can state the question precisely now, _not_ whether you can answer it now." A resolved ticket "clears the fog ahead of it, graduating whatever's now specifiable into fresh tickets."

The charting steps are these: name the destination, grill breadth-first, make the map, make the tickets and then connect the blocking links, and start the research subagents in parallel. "A HITL ticket only resolves through that live exchange; the agent never stands in for the human's side of it."

### Three skills were read only as summaries

`to-spec` (summary only, the full text was not read) turns a finished conversation into a spec. The spec has the problem, the solution, the user stories, the implementation decisions, the testing decisions, and the out-of-scope items. The skill explores the code for seams. It asks no new questions.

`prototype` (summary only) writes throwaway code that answers one design question (a logic demo or UI variants). Record the question and the verdict.

`to-questionnaire` (summary only) drafts questions for a third party. It does not apply to unattended runs.

Not verified: his posts and videos (not fetched), and the text of `to-tickets` and `implement`.

## Comparison: the repo attacks a finished plan but does not walk the branches

State on 2026-11-24: the column "Repo before the run" is the state of 2026-10-01. The run that followed this note replaced the flat Open questions list with the `## Unknowns` table (`.claude/skills/deliver/SKILL.md`).

| Matt idea | Repo before the run | Verdict |
|---|---|---|
| Design tree and frontier (ask the questions that have no open prerequisite) | Phase 1 "Open questions, each answered with a logged default". A flat list with no dependency order. | Add the dependency order. The cost is low. |
| Facts are the job of the agent, decisions are the job of the user | Autonomy rules: choose a default, log it, and ask only for an irreversible or outward action. Phase 1: probe a limit before a default. | Duplicate. The repo is stricter about when to ask. |
| A round of questions with a recommended answer | The same as a logged default | Duplicate |
| An empty frontier as the exit rule | The Phase 3 gate closes after N review rounds, not when the unknowns reach zero. | Missing. Review rounds find unknowns late. |
| Fog ("Not yet specified") against a ticket | No place for "I see a question but cannot phrase it". Plan gates found gaps that the plan never listed. | Missing |
| Ticket types: research, prototype, grilling, and task | The Phase 1 probe, the `research` skill, and the architect probe. No "prototype for a visual or feel question". | The prototype type is the gap. The live-take run found 3 on-screen defects only in Phase 7. |
| The map as an index, with one home for each decision | `decisions.tsv` plus `docs/decisions/` | Duplicate |
| Charting, tickets the size of one session, and a tracker | The run folder. One run is one goal. | Do not adopt. Wayfinder is for goals larger than one run. Use it only when `deliver` splits a goal. |
| `grill-with-docs` writes the glossary and the ADRs during the work | `domain-modeling` | Duplicate |
| `to-spec` | `analysis.md` plus `plan.md` | Duplicate |

Interrogate (the premortem, devil's advocate, and architecture lenses) attacks a finished plan. Grilling builds the plan as it walks the branches. The repo has the attack and does not have the walk.

## Recommendations: three small changes to deliver and interrogate

1. **In `deliver/SKILL.md` Phase 1, replace "Open questions, each answered with a logged default" with an unknowns ledger.** Write `## Unknowns` in `analysis.md`. Each row has a question, a depends-on (another row or none), a resolver (`code`, `probe`, `research`, `prototype`, `default`, or `user`), a status, and the answer with its evidence. First resolve the rows that have no open parent (the frontier). A resolved answer can add rows. Split the rows into **Sharp** (you can state the question) and **Fog** (you cannot state it yet). For a Fog row, name the area and the trigger that will make it sharp. The exit rule: no Sharp row is open, and each Fog row either graduated or is in the plan as a spike in the first slice. Use `user` only for an irreversible action or for a product choice with no Hindenburg reference. For a `user` row, log the default, continue, and put the row in `## Next` of the backlog. Do not block. Why: today the unknowns hide in prose. The gate cannot check a list that does not exist. An "empty frontier" gives a stop rule that does not depend on the luck of the reviewers.

2. **In `deliver/SKILL.md` Phase 2 and in `interrogate` Step 2, add a "prototype" resolver for look-and-feel unknowns before the plan gate.** For each criterion about what a user sees or feels (the timeline, the live waveform, or the scroll follow), build a throwaway in the run folder (in the probe.sh sandbox). Take a screenshot with `scripts/screenshot.sh`. Record the question and the verdict in the Unknowns row. This step adapts `prototype`: the agent itself judges against the reference behavior (Hindenburg), with no human reaction. Why: the live-take run found three on-screen defects only in Phase 7, after the code existed. Limit the step to changes of the `sources` class with a visible criterion, so the cost stays low.

3. **In `interrogate/SKILL.md` Step 2 and in the `premortem` lens, pass `## Unknowns` of `analysis.md` as input and add one lens question: "what unknown is missing from this list?"** Add each Act-on finding that shows a missing unknown to the ledger with its resolver. Then `decisions.tsv` shows the count of misses, and Phase 1 of the next run can learn from it (input for `reflect`). Why: plan gates already find gaps that the plan never listed. This change makes the search for those gaps the explicit job of the lens, and it measures the result.

Not adopted:

- The wayfinder map and tracker. They are too heavy for goals of one run. Look at them again if a goal needs more than one run.
- HITL grilling rounds. They block on the user. That goes against the autonomy rules.
- `to-questionnaire`.

## Sources

- https://github.com/mattpocock/skills (tree listed with `gh api`, 2026-10-01)
- https://raw.githubusercontent.com/mattpocock/skills/main/skills/engineering/wayfinder/SKILL.md (full text)
- `skills/productivity/grilling/SKILL.md` and `docs/productivity/grilling.md` through `gh api repos/mattpocock/skills/contents/...` (the skill read in full, the docs page in part)
- `skills/productivity/grill-me`, `skills/engineering/grill-with-docs`, `to-spec`, `to-questionnaire`, and `prototype`: raw pages through WebFetch summaries only (not verbatim)
- Repo: `.claude/skills/deliver/SKILL.md`, `interrogate/SKILL.md`, `architect/SKILL.md`, `domain-modeling/SKILL.md`, and `THIRD_PARTY.md`
