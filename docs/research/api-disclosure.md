# Progressive disclosure of APIs and tools to agents

Date: 2026-10-02

The question: what does an agent see first, what does it load on demand, and how does that map to the skills, references, scripts, AGENTS.md, and word budgets of this repo?

Fetch notes:

- The two X posts and the full thread came as JSON from `api.fxtwitter.com` (`/2/thread/<id>` and `/2/conversation/<id>`). The quotes are exact. I viewed the five images.
- The Claude Code memory page and the platform Agent Skills overview came as full text. The quotes are exact.
- The engineering posts, the Claude Code skills and sub-agents pages, the WWDC22 page, and the Swift guidelines came through WebFetch summaries. Treat their quotes as near-exact.
- `docs/research/agent-instruction-files.md` already holds the skill loading levels, the 500-line limit, the 1,024-character description limit, and the "one level deep" rule (its findings 7, 9, 10). This file does not repeat them.

## Source 1: Thomas Karatzas, API design thread

Thread start: https://x.com/karatzas_thomas/status/2105691392169394384 (2026-10-01). The author was a Staff Engineer at Apple and worked on App Intents and WidgetKit. The thread has seven posts by the author and no external links. Each post, in order:

1. "Here are some non-obvious tips for API design and maintainability."
2. **Reduce public symbols.** "Once it's public, it's impossible to rip out." `SnippetIntent` reused old types: it "legit just enforced the return type of the perform() method". The post says: "A ton of new functionality, no new API surface, that's a win!"
3. **Clean call sites at the cost of the declaration.** "Optimize for clean call sites at the cost of the declaration." The image shows the `List` initializer. Its declaration has a long `where` clause, but a call to it is short.
4. **Progressive disclosure.** "API design is actually super similar to landing page design. User should know what you do in 2 seconds, then make it easier to learn more. SwiftUI is a golden example of this." The image shows four `Button` forms, from `Button("Save")` up to a UIKit wrapper.
5. **Remove dependencies.** "The more dependencies your API has, the more you adopters have as well." The post also says: "Sometimes, a little bit of repetition is recommended here."
6. **Keep things opaque.** "Only expose the capabilities the next layer needs!" With `some View`, "the implementation can change but the public contract remains the same".
7. **Short tips:**
   - "avoid string types: No autocomplete and adopters get mad"
   - "design the client API first then implement it"
   - "Errors are part of the API as well"
   - "Make expensive operations a method and document it. Nothing is worse than when a getter secretly does I/O."

The author also replied in the thread:

- To "Do these still apply when an AI runs your API most of the time?", he wrote: "Yes because your users agents will get mad otherwise". He added that a badly built API still breaks clients over releases, "That doesn't matter if agents write code or not."
- To a question on maintainability patterns, he wrote: "Layering and composability!"

The owner source for post 4 is Apple. In WWDC22 session 10059, Sam Lazarus says: "Progressive disclosure, then, is designing APIs so that the complexity of the call site grows with the complexity of the use case." The session also says: "Compose, don't enumerate." (https://developer.apple.com/videos/play/wwdc2022/10059/)

The Swift API Design Guidelines give the owner rules for posts 3 and 7:

- "Clarity at the point of use."
- "Document the complexity of any computed property that is not O(1). People often assume that property access involves no significant computation."

(https://www.swift.org/documentation/api-design-guidelines/)

Inference: the thread is about Swift APIs for human developers. It does not talk about how agents load skills or context. Each mapping to the workflow of this repo below is an analogy. The Anthropic pages are the owner sources for the claims about agents.

## Source 2: Andrej Karpathy, reading LLM output

Post: https://x.com/karpathy/status/2105819303471976479 (2026-10-02). **This post is not about API disclosure.** It is about output formats that help a person understand what an LLM did. It has no links. Its image is a one-page overview of ASD-STE100.

- "Ask your LLM to explain something in ASD-STE100 ... it comes with heavy constraints on clean writing style that I often find a lot more readable."
- "Sometimes I've tried to soften it a bit e.g. ask for '80% of the way to ASD-STE100' because the spec is quite stringent."
- After STE, it ranks diagrams higher, then "in HTML" web pages, then "fully custom / bespoke explainer videos".
- Summary: "a lot more of our work will rise up the abstractions into oversight and understanding", and you can "ask for large, custom, discardable software artifacts".

The post itself has no more text. No reply by Karpathy is in the thread.

## Source 3: Anthropic on disclosure to agents

1. **Three loading levels for skills, with costs.** Level 1 is metadata: "Always (at startup)", "~100 tokens per Skill". Level 2 is the SKILL.md body: "When Skill is triggered", "Under 5k tokens". Level 3 is the bundled files: "None until accessed". The page also says: "Scripts run through bash, and only their output enters context." "the script's code never loads into the context window."
   https://platform.claude.com/docs/en/agents-and-tools/agent-skills/overview
2. **Invoked skill text stays.** "the rendered `SKILL.md` content enters the conversation as a single message and stays there across later turns." After auto-compaction, Claude Code fills a budget "starting from the most recently invoked skill ... keeping the first 5,000 tokens of each". Older skills "can be dropped entirely".
   https://code.claude.com/docs/en/skills
3. **The listing of skill descriptions has a budget.** "The budget scales at 1% of the model's context window. When the listing overflows, Claude Code drops descriptions starting with the skills you invoke least". `/doctor` estimates the listing cost, and `/skill-doctor` gives the cost and use of each skill. The `skillOverrides` setting has the states `on`, `name-only`, `user-invocable-only`, and `off`. The `/skills` menu saves it to `.claude/settings.local.json`.
   https://code.claude.com/docs/en/skills
4. **Point to each support file and say when to read it.** "Reference supporting files from `SKILL.md` so Claude knows what each file contains and when to load it".
   https://code.claude.com/docs/en/skills
5. **The built-in Plan and Explore agents do not load AGENTS.md.** A non-fork subagent loads "every level of the CLAUDE.md hierarchy ... and any AGENTS.md files loaded as project instructions. The built-in Explore and Plan agents skip this." `omitClaudeMd: true` removes these files from a custom subagent. The `skills` field preloads the full text of a skill.
   https://code.claude.com/docs/en/sub-agents
6. **Path-scoped rules.** "Path-scoped rules trigger when Claude reads files matching the pattern, not on every tool use." The memory page says: "If an entry is a multi-step procedure or only matters for one part of the codebase, move it to a skill or a path-scoped rule instead." After `/compact`, such rules "reload as Claude reads files they apply to".
   https://code.claude.com/docs/en/memory
7. **Load tools on demand.** Tool Search with `defer_loading: true`: "58 tools consuming approximately 55K tokens before the conversation even starts". With it, accuracy went up, for example "Opus 4 improved from 49% to 74%". Use it when "Tool definitions consuming >10K tokens". With programmatic tool calling, average tokens went "from 43,588 to 27,297". Tool use examples raised accuracy "from 72% to 90% on complex parameter handling".
   https://www.anthropic.com/engineering/advanced-tool-use (2025-11-24)
8. **Tools as files.** "Presenting tools as code on a filesystem allows models to read tool definitions on-demand". A `search_tools` tool has "a detail level parameter". Token use went "from 150,000 tokens to 2,000 tokens".
   https://www.anthropic.com/engineering/code-execution-with-mcp (2025-11-04)
9. **Tool design.** Five rules from the post:
   - "More tools don't always lead to better outcomes."
   - Namespace related tools.
   - "return only high signal information".
   - A `response_format` of `"concise"` or `"detailed"`.
   - Error responses that "clearly communicate specific and actionable improvements, rather than opaque error codes or tracebacks". Name parameters without ambiguity: `user_id`, not `user`.
   https://www.anthropic.com/engineering/writing-tools-for-agents (2025-09-11)
10. **Just-in-time context.** Agents "maintain lightweight identifiers ... and use these references to dynamically load data". The post describes a hybrid: "CLAUDE.md files are naively dropped into context up front, while primitives like glob and grep allow it to navigate". It also says: "If a human engineer can't definitively say which tool should be used in a given situation, an AI agent can't be expected to do better".
    https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents (2025-09-29)
11. **Skills post.** "If certain contexts are mutually exclusive or rarely used together, keeping the paths separate will reduce the token usage."
    https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills (2025-10-16)

## What the repo already does

Each item below matches a source. Each needs no change.

- **Point to a reference with its trigger.** `deliver`, `tdd`, `verify-this`, and `interrogate` say "Read `references/X` when ...". This matches source 3, item 4.
- **Return only the output that the agent needs.** Each script does the work and prints a short result: `cost.sh`, `check-changed.sh`, `evals-for.sh`, `seen.sh`, `pr-terms.sh`. This matches the level 3 script rule (item 1) and programmatic tool calling (item 7).
- **Errors are part of the API.** `land.sh` prints its usage and exits 2 on wrong arguments. Most scripts have a `# Usage:` header. `bundle.sh`, `dmg.sh`, and `test-dmg.sh` have none, and no script reads `--help`. The `check-docs.sh` errors name the file and the problem.
- **Design the call site first.** The `architect` package writes "the caller's usage ... first" (`architect/SKILL.md`, line 86).
- **Limit the public surface.** `docs/workflow/budgets.tsv` and the reflect rule "replace, not add" limit new public text. Karatzas post 2 says the same thing for API symbols.
- **Write in STE.** STE is already the rule for all text (AGENTS.md, Communication). Karpathy reports that STE output reads well. The `writing-for-humans` skill already handles PR text for a reader who did not follow the work.

## Changes for this repo

Each change is small. I rank them by expected value per cost.

### 1. Give the architect Plan agents the AGENTS.md rules

- **Problem:** `architect` Phase B starts built-in `Plan` subagents (`architect/SKILL.md`, line 36). Built-in Plan agents skip AGENTS.md (source 3, item 5). `references/runner-prompt.md` points to `docs/principles.md` but never to AGENTS.md. The Phase A text (lines 20-32) also does not tell the lead to pass the Architecture rules. So a candidate design can break a rule that it never saw: "Simple first", Concurrency, Audio callbacks, CLI parity, or File size.
- **Change:** add one line at the top of `references/runner-prompt.md`: "Read the Architecture rules and Testing rules of `AGENTS.md` first. The Plan agent does not load AGENTS.md." Another option is to start `general-purpose` agents, which load it.
- **Effect:** fewer candidates that the plan gate rejects for a repo rule. The cost is one line, about 25 words in the `architect` budget row.
- **Not verified:** I did not check the old run ledgers for a candidate that broke an AGENTS.md rule. The doc fact is verified. The effect on a run is not.

### 2. Make the Commands table of AGENTS.md shorter

- **Problem:** the table has 24 rows and about 436 words. That is about 24% of AGENTS.md. Every session and every non-Plan, non-Explore subagent loads it (source 3, item 5). A deliver run starts many reviewer subagents, so each word costs once per agent.
- **Change:** keep the rows that skills or daily work use. These are `setup`, `build`, `test`, `test-filter`, `test-slow`, `bench`, `app`, `run`, `lint`, `check-changed`, `check`, `test-app`, `test-dmg`, `test-hooks`, and the `dirigible` CLI. Keep `setup` because only AGENTS.md tells a new clone to enable the pre-commit hook. Move these rows to the Makefile comments: `check-slow-gates`, `bench-pairs.sh`, `icon-preview`, `dmg`, `format`, `check-docs`, `check-warnings`, `check-fast`, and `clean`. Add one row: "The Makefile comments list the other targets."
- **Check:** `check-docs.sh` (lines 46-53) checks only that each row has a target, not that each target has a row. So the check still passes. The skills name `make test-hooks` 9 times, so its row stays.
- **Effect:** about 150 words less in each agent context (inference: about 18 words per row, 9 rows). This is Karatzas post 4: tell the reader what the repo does fast, then point to more. Set the `AGENTS.md` row of `budgets.tsv` by the repo rule: row = `wc -w` x 1.1, up to the next 10, never above the old row. Lower the `TOTAL` row to match.

### 3. Move the Diátaxis section out of technical-writing

- **Problem:** `technical-writing/SKILL.md` has 1,731 words. Its Diátaxis section has 322 words, and only a new or restructured doc page needs it. A commit message, a ledger row, or a review finding does not need it. Invoked skill text stays in the conversation (source 3, item 2), and each writer subagent loads it again. Source 3, item 11, says to keep rarely used paths separate. The branch test in `writing-for-agents` says the same.
- **Change:** move the section to `technical-writing/references/diataxis.md`. Put this pointer in its place: "Read `references/diataxis.md` when you write or restructure a page in `docs/`."
- **Budgets:** add a row for the reference file, lower the SKILL.md row by the same number, and keep the folder row. A grep of `.claude/`, `docs/workflow/`, `docs/principles.md`, and AGENTS.md found no other pointer to the Diátaxis heading. So no other file changes. The skill is an adapted copy of `pstack` (`THIRD_PARTY.md`). The repo already adds references to adapted skills (for example `tdd`), so the split is allowed.
- **Effect:** about 320 words less for each use that is not a doc page.

### 4. Measure the skill listing, then hide the skills that this repo does not use

- **Problem:** this session lists more than 100 user-level skills, for example the Compose, Android, and design skills. The listing budget is 1% of the context window. When the listing overflows, Claude Code drops descriptions, starting with the skills that you invoke least (source 3, item 3). A subagent on a 200k-token model gets one fifth of the budget of a 1M-token session. So a project skill such as `tdd` or `research` can lose its description and stop triggering (inference).
- **Change:** run `/doctor` and `/skill-doctor` in a session of this repo. If the listing overflows, set the unrelated user skills to `"off"` or `"name-only"` in `skillOverrides` in `.claude/settings.local.json`. This file is per user and not in git.
- **Not verified:** I did not see `/doctor` output, so I do not know that the listing overflows. The user must run the command, because it is interactive. Ask before you hide the user's own skills.

## Ideas that do not apply, and why

- **Tool Search and `defer_loading`.** The repo defines no tools and has no `.mcp.json`. Claude Code already defers its own tools.
- **A `response_format` parameter on scripts.** The scripts already print short output. No ledger row shows an agent drowning in script output.
- **Path-scoped rules for the Architecture rules.** A rule with `paths:` loads only when Claude reads a matching file (source 3, item 6). The rules for Audio callbacks and Concurrency prevent crashes. A Write of a new file before any Read would not load them. CLI parity and Localized UI are also needed at plan time, before any file is read. Keep all of them in AGENTS.md.
- **`omitClaudeMd` on the reviewer agents.** The reviewers need STE and the repo rules to judge a diff. Leave them as they are.
- **A rubric line for "a getter does I/O".** A grep of computed properties in `Sources/` found no property that does file I/O. With no case on record, the reflect rule (seen once before a rule) does not allow a new rule.
- **Softer STE ("80% of the way").** Karpathy uses this for reading explanations, not for maintenance text. The repo chose strict STE in AGENTS.md. `writing-for-humans` already makes PR bodies easier to read. No evidence supports a change.
- **Diagrams, HTML, and video for understanding (Karpathy).** The `pr` skill already allows Mermaid diagrams. An HTML run report is optional for the user. It does not belong in the workflow until a reader asks for it.
- **"Remove dependencies" and "keep things opaque" (Karatzas posts 5 and 6).** These apply to the Swift module API. The architecture rules ("Simple first", the dependency direction, decision records for a third-party package) already cover them.

## Not verified

- Each engineering-post quote is a near-exact quote from a WebFetch summary, not the full page.
- The overflow of the skill listing in this repo (change 4).
- The effect on a run of the missing AGENTS.md in Plan agents (change 1). I did not search the ledgers for a real case.
- The word savings of changes 2 and 3 are estimates from `wc -w` of the sections, not from measured tokens.

## Sources

- Thomas Karatzas, thread, 2026-10-01: https://x.com/karatzas_thomas/status/2105691392169394384 (JSON: https://api.fxtwitter.com/2/conversation/2105691392169394384)
- Andrej Karpathy, post, 2026-10-02: https://x.com/karpathy/status/2105819303471976479 (JSON: https://api.fxtwitter.com/karpathy/status/2105819303471976479)
- Apple, WWDC22 session 10059, "The craft of SwiftUI API design: Progressive disclosure": https://developer.apple.com/videos/play/wwdc2022/10059/
- Swift API Design Guidelines: https://www.swift.org/documentation/api-design-guidelines/
- Anthropic, Agent Skills overview: https://platform.claude.com/docs/en/agents-and-tools/agent-skills/overview
- Claude Code, Skills: https://code.claude.com/docs/en/skills
- Claude Code, Subagents: https://code.claude.com/docs/en/sub-agents
- Claude Code, Memory: https://code.claude.com/docs/en/memory
- Anthropic, "Introducing advanced tool use", 2025-11-24: https://www.anthropic.com/engineering/advanced-tool-use
- Anthropic, "Code execution with MCP", 2025-11-04: https://www.anthropic.com/engineering/code-execution-with-mcp
- Anthropic, "Writing effective tools for agents", 2025-09-11: https://www.anthropic.com/engineering/writing-tools-for-agents
- Anthropic, "Effective context engineering for AI agents", 2025-09-29: https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents
- Anthropic, "Equipping agents for the real world with Agent Skills", 2025-10-16: https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills
- Repo: `docs/research/agent-instruction-files.md`, `.claude/skills/architect/SKILL.md`, `.claude/skills/architect/references/runner-prompt.md`, `.claude/skills/technical-writing/SKILL.md`, `.claude/skills/THIRD_PARTY.md`, `scripts/check-docs.sh`, `docs/workflow/budgets.tsv`
