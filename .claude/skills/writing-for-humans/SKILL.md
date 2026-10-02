---
name: writing-for-humans
description: "Revise prose for a person who did not follow the work. Use for a PR body, a report, or a request to make text readable."
---

## Ground rules

- Keep each fact, number, hedge, link, heading, and code span that `scripts/pr-terms.sh` does not flag. Add no claim and no intensifier.
- On a conflict with STE (the **technical-writing** skill), STE wins.
- `scripts/pr-terms.sh` is the minimum check. The cold reader judges the rest.
- A PR body is a briefing that a reviewer reads in under a minute. Long lists and tables go in the audit block of the **pr** skill.

## Passes

Do each pass once, in order, over the whole text.

0. Copy `pr.md` to `<run>/logs/pr-draft.md`.
1. **Terms.** Run `scripts/pr-terms.sh <run>/pr.md`. Write each run-internal ID as its meaning, also in code font. Replace each commit hash with the change in words: the PR Commits tab lists them. Keep a resolvable ID only in parentheses after its words. Define or replace each coined term at its first use.
2. **Skim layer.** The first two or three sentences say what changed for the user or the maintainer, why, and the risk.
3. **Actors and actions.** Change each abstract noun that hides a verb behind an empty verb (make, perform, occur) to that verb, with the actor as its subject (the Active voice rule of the **unslop** skill).
4. **Old before new.** Start each sentence with what the reader already knows, and end it on the new point. Check that the subjects of a paragraph are one short set of actors.
5. **Unpack and cut.** Apply the Over-compression, Filler phrases, and Prefer the plain word rules of **unslop**, and the noun-string rule of **technical-writing**. Keep a hedge that carries evidence.
6. **Facts.** Run `scripts/pr-terms.sh --lost <run>/logs/pr-draft.md <run>/pr.md`. Restore each number that it prints.
7. **Cold reader.** Give one new subagent only the body, in a new folder outside the repo. It returns what changed, why, the risk, and what the user must do. Revise each sentence that it misreads. Do at most two rounds.

Stop when both `pr-terms.sh` runs exit 0 and the cold reader states the four points.

## Example

Before:

> D4: the hand-off wait guarded only the tick path. Fixed in 628662d (one rule for the tick and updateLayer).

After:

> When a take stops, the timeline keeps the live box until the final clips replace it. Both redraw paths now wait, the timer tick and `updateLayer`; before, only the tick waited.

Source: Joseph M. Williams, Style: Ten Lessons in Clarity and Grace.
