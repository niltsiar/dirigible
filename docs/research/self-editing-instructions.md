# Self-improving instructions: what Anthropic says

Date: 2026-09-30

Scope: agents that edit their own CLAUDE.md, skills, or memory, and how to keep those instructions coherent. "P" = primary source, "S" = secondary. The quotes came through a fetch tool that summarizes pages. Treat the wording as near-exact, not byte-exact, unless a quote is long and in a block. No video timestamps were found (unverified).

## Findings

1. **Add a rule when the same mistake repeats.**
   "Add to it when: Claude makes the same mistake a second time; A code review catches something Claude should have known about this codebase; You type the same correction or clarification into chat that you typed last session; A new teammate would need the same context to be productive."
   Speaker: Claude Code docs (Anthropic). https://code.claude.com/docs/en/memory (section "When to add to CLAUDE.md"). P.

2. **The trigger also tells you when to update, not only when to add.**
   "The same triggers tell you when to update what you already have. A repeated mistake or a recurring review comment is a CLAUDE.md edit, not a one-off correction in chat. A workflow you keep tweaking by hand is a skill that needs another revision." Trigger table: "Claude gets a convention or command wrong twice -> Add it to CLAUDE.md".
   Speaker: Claude Code docs. https://code.claude.com/docs/en/features-overview (section "Build your setup over time"). P.

3. **Boris Cherny: tell Claude to write the rule.**
   "if you see a mistake, I'll just be like, at Claude, add this to Claude MD so that the next time it just knows this automatically."
   Speaker: Boris Cherny, on the Every podcast (AI & I, with Cat Wu). https://every.to/podcast/transcript-how-to-use-claude-code-like-the-people-who-built-it. P (first-person transcript; no timestamp found; unverified).
   Same idea in his team tips (his X thread, 402 when fetched): update CLAUDE.md "whenever Claude does something wrong so future sessions start with better context"; in PR review tag the bot so feedback becomes a CLAUDE.md change. Seen only through a gist copy: https://gist.github.com/joyrexus/e20ead11b3df4de46ab32b4a7269abe0. S. Original: https://x.com/bcherny/status/2017742747067945390 (not readable here).

4. **Cat Wu: some staff make Claude keep a diary per task.**
   "There are some people at Anthropic where for every task they do, they tell Claude Code to write a diary entry in a specific format." She says "some people swear by it". It is a memory-synthesis habit, not an endorsed default.
   Speaker: Cat Wu, same Every transcript. P (no timestamp).

5. **Bloat is the named failure. Prune, and test by watching behavior.**
   "Keep it concise. For each line, ask: 'Would removing this cause Claude to make mistakes?' If not, cut it. Bloated CLAUDE.md files cause Claude to ignore your actual instructions!"
   "If Claude keeps doing something you don't want despite having a rule against it, the file is probably too long and the rule is getting lost... Treat CLAUDE.md like code: review it when things go wrong, prune it regularly, and test changes by observing whether Claude's behavior actually shifts."
   "The over-specified CLAUDE.md... Fix: Ruthlessly prune. If Claude already does something correctly without the instruction, delete it or convert it to a hook."
   Speaker: Anthropic docs. https://code.claude.com/docs/en/best-practices. P.

6. **Size cap and ownership.**
   "target under 200 lines per CLAUDE.md file. Longer files consume more context and reduce adherence." Imports "don't reduce its context cost, because imported files also load at launch."
   "In a shared repository, CLAUDE.md grows the way any unowned config file does: every team appends its own instructions and nothing gets deleted... Keep CLAUDE.md under 200 lines, give it an owner, and review changes to it like code."
   Speakers: docs https://code.claude.com/docs/en/memory (P); blog https://claude.com/blog/steering-claude-code-skills-hooks-rules-subagents-and-more (P).

7. **Conflicts and audits.**
   "if two instructions contradict each other, Claude may pick one arbitrarily. Review your CLAUDE.md files, nested CLAUDE.md files in subdirectories, and .claude/rules/ periodically to remove outdated or conflicting instructions." Tool: `/doctor prompt-audit` finds "instructions written for older models, references to files or commands that don't exist, and files that contradict each other... nothing in your files changes until you ask Claude to apply them." `/doctor` also proposes cuts of content derivable from the codebase.
   Speaker: docs. https://code.claude.com/docs/en/memory. P. (Needs Claude Code v2.1.283+, per the page.)

8. **Advisory vs enforced: move must-hold rules to hooks; emphasis only on one line.**
   "An instruction like 'never edit .env' in CLAUDE.md or a skill is a request, not a guarantee... If a rule must hold every time, make it a hook." Also: "If you emphasize many lines, none of them stands out."
   Speaker: docs. https://code.claude.com/docs/en/features-overview and best-practices. P.

9. **Procedures go to skills, not CLAUDE.md. Skills improve from reflection on real runs.**
   "Procedures belong in skills. CLAUDE.md is for facts Claude should hold all the time."
   Skills blog: "Ask Claude to capture its successful approaches and common mistakes into reusable context and code within a skill." "If it goes off track when using a skill to complete a task, ask it to self-reflect on what went wrong." "Monitor how Claude uses your skill in real scenarios and iterate based on observations."
   Speaker: Anthropic engineering. https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills (P).

10. **Evals for instruction changes: with/without, blind A/B, regression.**
    "Comparator agents for A/B comparisons: two skill versions, or skill vs. no skill. They judge outputs without knowing which is which, so you can tell whether a change actually helped."
    "If the base model starts passing your evals without the skill loaded, that's a signal the skill's techniques may have been incorporated into the model's default behavior." Evals also warn "when something shifts" on a new model.
    Speaker: Anthropic (claude.com blog). https://claude.com/blog/improving-skill-creator-test-measure-and-refine-agent-skills. P.
    Tool-writing post: "relied on held-out test sets to ensure we did not overfit to our 'training' evaluations"; "Simply concatenate the transcripts from your evaluation agents and paste them into Claude Code." https://www.anthropic.com/engineering/writing-tools-for-agents. P.

11. **Context engineering: fewer, higher-signal tokens; avoid brittle hardcoded logic.**
    "finding the smallest possible set of high-signal tokens that maximize the likelihood of some desired outcome." Context rot: "as the number of tokens in the context window increases, the model's ability to accurately recall information from that context decreases." Warns of "hardcoding complex, brittle logic in their prompts... creates fragility and increases maintenance complexity over time." Right altitude: "specific enough to guide behavior effectively, yet flexible enough to provide the model with strong heuristics."
    Speaker: Anthropic engineering. https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents. P.

12. **Long-running harnesses and memory tool: durable notes, guarded checklists.**
    Harness post: a progress log file; feature list JSON with a `passes` field; "It is unacceptable to remove or edit tests because this could lead to missing or buggy functionality." Agents declared work done too early. https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents. P.
    Memory tool: Claude can "create, read, update, and delete files in a dedicated memory directory"; with context editing a "39% performance boost" on internal tests. https://claude.com/blog/context-management. P.
    Auto memory (Claude Code): first 200 lines or 25KB of MEMORY.md load; near the limit, Claude Code tells Claude to "keep one line per entry, move detail into topic files, and merge or drop stale entries." https://code.claude.com/docs/en/memory. P.

## Gaps
- No Anthropic source found that shows an agent auto-editing CLAUDE.md after every task with an eval gate. Anthropic's pattern is human-triggered ("add this to CLAUDE.md") plus review in PRs. Auto memory is the closest automatic loop, and it is separate from CLAUDE.md and machine-local.
- No data found on how many rules cause conflicts. The 200-line figure is guidance, not a measured limit (unverified).
- Boris's X thread and Lenny's podcast were not readable; timestamps missing.
- Third-party claims ("under 500 lines fully followed", "165 repos") seen in search snippets are not sourced to Anthropic. Ignored.

## Implications for a reflect loop (inference)

This section is inference from the findings. No source states these items as rules for this repo.

1. **Trigger.** Write a rule only on evidence: same mistake twice, a review finding, or the same correction typed twice (docs, finding 1). A one-off lesson stays in the run log, not in AGENTS.md.
2. **Choose the home by load cost.** Always-true fact or command: AGENTS.md. Multi-step procedure: skill. Must never fail: hook or check (docs prefer this). Path-specific: scoped rule. Per-run state: ledger or auto memory.
3. **Replace before add.** Before each new line, search for a rule on the same topic. Merge or rewrite it. A new rule that contradicts an old one is a defect (finding 7). Each rule line should say what to do in concrete, checkable words.
4. **Net-size budget.** Keep AGENTS.md at or under about 200 lines (Anthropic guidance; the repo file may already differ, check). When a reflect run adds a line, it must remove or move one, or say why not.
5. **Periodic prune.** Every N runs, for each line ask "would removing this cause a mistake?" Delete lines that Claude does right without them. Run an audit pass (`/doctor prompt-audit` or an equal subagent) for stale paths, dead commands, and conflicts. Re-run after a model change, because uplift rules can become dead weight (finding 10).
6. **Evals for a change.** For a behavior rule, keep the failing case as a replay: run the task with and without the new rule (blind A/B when output is subjective). Keep the rule only if behavior shifts. Hold out cases to avoid fitting the rule to one example (tools post). Cheap version: the rule names a check (test, script) that fails without it. This matches "test changes by observing whether Claude's behavior actually shifts".
7. **Prefer a check over a sentence.** If the rule must hold, add a hook or test and skip the prose (finding 8). `docs/principles.md` already states this preference (`encode-lessons-in-structure`).
8. **Who reviews.** A human reviews every instruction diff in the PR, like code, with a named owner (finding 6). The agent proposes; it does not merge its own rule edits unreviewed. A separate fresh-context subagent may check the diff for conflicts and bloat.
9. **Emphasis.** Do not add IMPORTANT to many lines. Use it on one line that still gets skipped after a rewording.
10. **Skill edits.** Change a skill from a real trajectory (what went wrong), then re-run its eval. Keep skill descriptions distinct, so triggers do not overlap.

## Sources
- https://code.claude.com/docs/en/memory (accessed 2026-09-30)
- https://code.claude.com/docs/en/best-practices
- https://code.claude.com/docs/en/features-overview
- https://claude.com/blog/steering-claude-code-skills-hooks-rules-subagents-and-more
- https://claude.com/blog/improving-skill-creator-test-measure-and-refine-agent-skills
- https://claude.com/blog/context-management
- https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents
- https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents
- https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills
- https://www.anthropic.com/engineering/writing-tools-for-agents
- https://every.to/podcast/transcript-how-to-use-claude-code-like-the-people-who-built-it (Boris Cherny, Cat Wu; first-person transcript)
- https://x.com/bcherny/status/2017742747067945390 (Boris Cherny thread; HTTP 402, unread)
- https://gist.github.com/joyrexus/e20ead11b3df4de46ab32b4a7269abe0 (secondary copy of team tips)
