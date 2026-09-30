# Anthropic guidance on writing and maintaining agent instructions

Date: 2026-09-30

All pages were fetched on 2026-09-30. The quotes come from the fetched page text. The skills, sub-agents, engineering, and skill-creator pages came through WebFetch summaries. The memory, best-practices, and authoring best-practices pages came as full text. A quote from a WebFetch summary can be shorter than the page text. Treat its wording as near-exact.

## Findings

1. **Context is the core constraint; bloat hurts adherence.**
   "Claude's context window fills up fast, and performance degrades as it fills." and "Bloated CLAUDE.md files cause Claude to ignore your actual instructions!"
   https://code.claude.com/docs/en/best-practices

2. **CLAUDE.md size budget: under 200 lines.**
   "Size: target under 200 lines per CLAUDE.md file. Longer files consume more context and reduce adherence." Imports do not help: "Imports help you organize a long file but don't reduce its context cost, because imported files also load at launch." Claude Code warns at startup when a file is over the length, and when files add up past a combined limit.
   https://code.claude.com/docs/en/memory

3. **Include only what Claude cannot derive; cut the rest.**
   "For each line, ask: 'Would removing this cause Claude to make mistakes?' If not, cut it." Exclude: "Anything Claude can figure out by reading code", "File-by-file descriptions of the codebase", "Information that changes frequently", "Long explanations or tutorials". The `/doctor` trim "cuts content Claude can derive from the codebase, such as directory layouts, dependency lists, and architecture overviews, and keeps pitfalls, rationale, and conventions that differ from tool defaults."
   https://code.claude.com/docs/en/best-practices ; https://code.claude.com/docs/en/memory

4. **Treat instructions like code: review, prune, test.**
   "Treat CLAUDE.md like code: review it when things go wrong, prune it regularly, and test changes by observing whether Claude's behavior actually shifts." Failure pattern: "The over-specified CLAUDE.md... Fix: Ruthlessly prune. If Claude already does something correctly without the instruction, delete it or convert it to a hook."
   https://code.claude.com/docs/en/best-practices

5. **Contradictions make Claude pick one at random; audit tooling exists.**
   "If two instructions contradict each other, Claude may pick one arbitrarily. Review your CLAUDE.md files, nested CLAUDE.md files in subdirectories, and .claude/rules/ periodically to remove outdated or conflicting instructions." `/doctor prompt-audit` (v2.1.283+) checks for "instructions written for older models, references to files or commands that don't exist, and files that contradict each other", and covers CLAUDE.md, AGENTS.md, rules, skills, commands, subagents.
   https://code.claude.com/docs/en/memory

6. **Emphasis dilutes.** "If you emphasize many lines, none of them stands out." The skill-creator says: "If you find yourself writing ALWAYS or NEVER in all caps... that's a yellow flag — if possible, reframe and explain the reasoning." Explain the why.
   https://code.claude.com/docs/en/best-practices ; https://github.com/anthropics/skills/blob/main/skills/skill-creator/SKILL.md

7. **Skill budget: SKILL.md body under 500 lines; split with progressive disclosure, one level deep.**
   "Keep SKILL.md body under 500 lines for optimal performance. Split content into separate files when approaching this limit." "Keep references one level deep from SKILL.md." "For reference files longer than 100 lines, include a table of contents at the top." "Reference files... don't consume context tokens until actually read." Skill-creator: three levels: metadata (~100 words, always loaded), body (<500 lines), bundled resources (as needed, unlimited; scripts run without loading).
   https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices ; https://github.com/anthropics/skills/blob/main/skills/skill-creator/SKILL.md

8. **Be concise in skills: challenge every paragraph.**
   "The context window is a public good." "Only add context Claude doesn't already have." "Does this paragraph justify its token cost?" Match freedom to fragility: low freedom (exact script) for fragile steps, high freedom (prose heuristics) when many approaches work. Do not list many options; give a default with an escape hatch.
   https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices

9. **Descriptions cost context all the time, and have caps.**
   Name max 64 chars; description max 1,024 chars. In Claude Code: "the combined description and when_to_use text is truncated at 1,536 characters in the skill listing"; the listing budget "scales at 1% of the model's context window"; with many skills, "Claude Code drops some descriptions to fit the listing's character budget, which removes the keywords Claude needs to match your request." Sub-agents: "Those descriptions take up context, so keep them short"; warning when combined subagent descriptions exceed 15,000 tokens.
   https://code.claude.com/docs/en/skills ; https://code.claude.com/docs/en/sub-agents

10. **What goes where.**
    - CLAUDE.md: "facts Claude should hold in every session: build commands, conventions, project layout, 'always do X' rules. If an entry is a multi-step procedure or only matters for one part of the codebase, move it to a skill or a path-scoped rule." (memory)
    - Skill: "Create a skill when... a section of CLAUDE.md has grown into a procedure rather than a fact." "a skill's body loads only when it's used, so long reference material costs almost nothing until you need it." (skills)
    - Rules with `paths:` frontmatter load only for matching files. (memory)
    - Subagent: "Use one when a side task would flood your main conversation with search results, logs, or file contents you won't reference again." (sub-agents)
    - Script: "Prefer scripts for deterministic operations"; scripts are "More reliable than generated code" and "Save tokens". If every test run rewrites the same helper, "that's a strong signal the skill should bundle that script." (authoring best practices; skill-creator)
    URLs: https://code.claude.com/docs/en/memory ; https://code.claude.com/docs/en/skills ; https://code.claude.com/docs/en/sub-agents ; https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices

11. **Hooks enforce; instructions advise.**
    "Claude treats them as context, not enforced configuration. To block an action regardless of what Claude decides, use a PreToolUse hook instead." "Unlike CLAUDE.md instructions which are advisory, hooks are deterministic and guarantee the action happens." "Use hooks for actions that must happen every time with zero exceptions." "If the instruction is something that must run at a specific point, such as before every commit or after each file edit, write it as a hook." Settings `permissions.deny` is the tool for blocking; "CLAUDE.md instructions shape Claude's behavior but are not a hard enforcement layer." A Stop hook can be "a deterministic gate" that blocks the turn from ending until a check passes.
    https://code.claude.com/docs/en/memory ; https://code.claude.com/docs/en/best-practices ; https://code.claude.com/docs/en/hooks-guide

12. **Build and iterate from evidence, not from anticipation.**
    "Create evaluations BEFORE writing extensive documentation." Steps: find gaps without the skill, build three scenarios, baseline, "Write minimal instructions... just enough content to address the gaps", iterate. "Iterate based on these observations rather than assumptions." Watch for "Ignored content: If Claude never accesses a bundled file, it might be unnecessary." Skill-creator: "Keep the prompt lean. Remove things that aren't pulling their weight. Make sure to read the transcripts." Test with Haiku, Sonnet, and Opus; Opus check is "Does the Skill avoid over-explaining?" Checklist asks for at least three evaluations.
    https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices ; https://github.com/anthropics/skills/blob/main/skills/skill-creator/SKILL.md

13. **Context engineering: minimal, right altitude, no brittle logic.**
    "You should be striving for the minimal set of information that fully outlines your expected behavior." "As the number of tokens in the context window increases, the model's ability to accurately recall information from that context decreases." Hardcoded "complex, brittle logic in their prompts... creates fragility and increases maintenance complexity over time." Prefer curated canonical examples.
    https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents

14. **Other maintenance facts.** Terminology: "Choose one term and use it throughout." Time-sensitive text goes in a collapsed "old patterns" section. HTML block comments in CLAUDE.md are stripped before injection, so they can hold maintainer notes at no token cost. Root CLAUDE.md survives `/compact`; conversation-only rules do not. Skills and CLAUDE.md content is "delivered as a user message after the system prompt", with "no guarantee of strict compliance".
    https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices ; https://code.claude.com/docs/en/memory

## Implications for a repo whose skills grew 4-5x by add-only patches (inference)

This section is inference from the findings. No source states these items as rules for this repo. Anthropic gives no number for total skill size across a repo. The hard numbers are: CLAUDE.md < 200 lines, SKILL.md body < 500 lines, reference TOC above 100 lines, description 1,024 chars (1,536 combined in the Claude Code listing), listing budget 1% of context. Each item below that is not a number is inference.

1. **Set budgets and check them with a script.** AGENTS.md/CLAUDE.md: aim under 200 lines (the repo file also pulls in the `make` table; check the length). Each SKILL.md under 500 lines; aim lower for skills that load on every run (inference). Description under 1,024 chars with the trigger first. Add a `make check` rule that fails on a SKILL.md over the cap, a reference over 100 lines with no contents list, and a link deeper than one level. A check beats a sentence (the repo already says this).
2. **Split by load time, not by topic order.** SKILL.md = trigger, flow, decision points, and links. Move phase detail, long checklists, templates, and examples to `references/<name>.md`, linked directly from SKILL.md (one level). Say for each link when to read it.
3. **Every line must pass the deletion test.** "Would removing this cause Claude to make mistakes?" For each add-only patch, find the failure that caused it. No failure on record: cut. Rule that Claude follows without the text: cut (best-practices: "delete it or convert it to a hook").
4. **Rewrite, do not append.** A patch that adds a sentence next to an older sentence on the same topic makes a near-contradiction. Edit in place; when a rule changes, remove the old rule. Merge duplicates across AGENTS.md, skills, and agent files: one home per rule, others link.
5. **Move enforceable rules out of prose.** Anything that must happen every time (format, build before commit, no force push, no write outside a folder) belongs in a hook, `permissions.deny`, a Makefile check, or a script. The repo already does this for git guardrails. Then delete the prose, or keep one line pointing to the check. Repeated multi-step shell sequences in a skill become a script in `scripts/` that Claude runs; the skill says "run X" and does not print the code.
6. **Keep judgment in prose, and explain why.** Reserve skill text for decisions a script cannot make. State the reason, and drop the capital ALWAYS/NEVER except on one or two lines.
7. **Keep history out of the instructions.** Incident stories, "learned in run N" notes, and dated facts go to decision records or the ledger, not to the skill. Skills describe current behavior only (time-sensitive rule). Use HTML comments for maintainer notes; they cost no tokens.
8. **Prune on a schedule and on evidence.** After each run, `reflect` should have a removal output, not only an add output: list lines that no transcript used (inference, from the "ignored content" guidance). Run `/doctor prompt-audit` (covers skills, agents, rules) on a cadence for stale paths and contradictions.
9. **Test changes like code.** For a rewrite of a skill, run 3 representative tasks before and after (authoring guide: at least three evaluations, baseline first). Keep the change only if behavior on the failures it targets is the same or better. Try the smaller model, since an over-long skill is written for the weakest reader.
10. **Keep listing text short.** With many skills and agents, descriptions compete for the 1% listing budget and get dropped. Shorten descriptions and put the trigger first. Mark manual-only flows `disable-model-invocation: true`, which keeps them out of auto-selection (skills page).
11. **Use subagents for volume, not for rules.** Put reading-heavy work (review, research) in a subagent so output stays out of the main context; keep subagent prompts focused, with restricted tools.

## Not verified from a primary page

- Any total-size limit across all skills or a per-repo cap. No primary page states one.
- Exact wording of quotes from the skills, sub-agents, engineering posts, and skill-creator pages: they come from summarized fetches. Numbers (500 lines, 1,536 chars, 1%, 15,000 tokens, 200 lines) were stated there and, for 500 and 200, also in full-text pages.
- "Aim lower than 500 for always-loaded skills" and the prune-by-transcript practice are inferences, not Anthropic statements.
- Claude Code version numbers (v2.1.283 for `/doctor prompt-audit`) come from the memory page and could change.

## Sources

- https://code.claude.com/docs/en/memory
- https://code.claude.com/docs/en/best-practices
- https://code.claude.com/docs/en/skills
- https://code.claude.com/docs/en/sub-agents
- https://code.claude.com/docs/en/hooks-guide
- https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices
- https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills
- https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents
- https://github.com/anthropics/skills/blob/main/skills/skill-creator/SKILL.md
