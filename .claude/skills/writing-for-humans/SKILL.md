---
name: writing-for-humans
description: "Revise a PR body for a person who did not follow the work. Use before `scripts/land.sh`."
---

## Ground rules

- Keep each fact, number, hedge, link, heading, and code span that `scripts/pr-terms.sh` does not flag. Add no claim and no intensifier.
- On a conflict with STE (the **technical-writing** skill), STE wins.
- A PR body is a briefing that a reviewer reads in under a minute. Long lists and tables go in the audit block of the **pr** skill.

## Passes

Do each pass once, in order, over the whole text.

0. Copy the body with no overwrite: `cp -n <run>/pr.md <run>/logs/pr-draft.md`.
1. **Terms.** Run `scripts/pr-terms.sh <run>/pr.md`. Then:
   1. Replace each flagged ID with its meaning in words, in plain text or in backticks.
   2. Replace each commit hash with the change in words. The PR Commits tab lists them.
   3. Keep a resolvable ID only in parentheses after its words.
   4. Define each term that the run made up, at its first use.
2. **Skim layer.** The opening sentences follow the Summary lines of the **pr** template.
3. **Actors and actions.** Find each abstract noun that hides a verb behind an empty verb (make, perform, occur). Then:
   1. Change the noun to its verb.
   2. Make the actor the subject of that verb (the Active voice rule of the **unslop** skill).
4. **Old before new.** Start each sentence with what the reader already knows, and end it on the new point. Check that the subjects of a paragraph are one short set of actors.
5. **Unpack and cut.** Apply the Over-compression, Filler phrases, and Prefer the plain word rules of **unslop**, and the noun-string rule of **technical-writing**. Keep a hedge that carries evidence.
6. **Facts.** Run `scripts/pr-terms.sh --lost <run>/logs/pr-draft.md <run>/pr.md`, the check of `scripts/land.sh`, and restore each number that it prints.
7. **Cold reader.** Paste the body into the prompt of a new general-purpose subagent. Tell it to use no tool and to read no file. It returns four labelled lines: what changed, why (the problem it solves), the risk, and what the user must do. Revise each sentence that it misreads. Do at most two rounds. After round two, stop, and list each misread point under the manual checks of the Review section.

Stop when both `pr-terms.sh` runs exit 0 and the four lines of the cold reader match the draft.

## Example

Before:

> D4: the hand-off wait guarded only the tick path. Fixed in 628662d (one rule for the tick and updateLayer).

After:

> When a take stops, the timeline keeps the live box until the final clips replace it. Both redraw paths now wait, the timer tick and `updateLayer`; before, only the tick waited.

Source: Joseph M. Williams, Style: Ten Lessons in Clarity and Grace.
