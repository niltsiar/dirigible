# 0051. The agent manual: one owner for the MCP instructions, the prompts, the skill, and `dirigible --instructions`

- Status: accepted
- Date: 2026-10-13
- Date accepted: 2026-10-13, after plan gates 1 and 2 of run `2026-10-13-agent-onboarding`.
- Amends: 0041 (the server sends `instructions` and serves `prompts/list` and `prompts/get`), 0011 (CLI parity: the root flag `--instructions` and the command `skill` are not package features, so they get no tool).

## Context

R16: agents read and edit sessions through `dirigible mcp`. A tester asked for "a skill to know how to use the MCP". The server sent only the tool list. A baseline eval with `claude -p` (run `2026-10-13-agent-onboarding`, eval E38) showed that agents do each single edit well from the tool descriptions. They fail where no tool exists. With a shell, they cannot find the CLI: it is not on `PATH`, and they do not know its path in the app. Claude Code, Codex, and opencode read the `instructions` of the server. Claude Code and opencode serve MCP prompts as commands. Claude Code reads skills in `~/.claude/skills`; Codex, opencode, and Cursor read `~/.agents/skills` (`docs/research/agent-onboarding.md`). Hindenburg PRO has no agent interface.

## Decision

- **One owner.** `AgentManual` in `DirigibleMCP` holds the manual: the core rules, then one line for each recipe. The MCP `instructions` (both eras), `dirigible --instructions`, the prompts, and the skill take their text from it. A test fails when the text names a tool, a tool argument, or a `dirigible` command line that does not exist or does not parse.
- **The CLI path.** The instructions and `--instructions` name the absolute path of the running `dirigible` once, after symlinks. So an agent with a shell can run the commands that have no tool. The skill names the path rule instead: resolve the skill folder with `realpath`, then run `Contents/Helpers/dirigible` of that app. For a copy of the skill, run `/Applications/Dirigible.app/Contents/Helpers/dirigible`, or ask the user.
- **The CLI record.** The manual shows `dirigible record` as a capability with a plain warning: it records at once from the routed devices, with no consent sheet. Run it only when the user asked for a recording. The `record` tool asks the user in the app (R16, 0048). A test fails when the example or its warning drops. Hiding a real capability does not stop abuse: the permission rules of the agent client are the gate (user decision, 2026-10-13). The agent eval runs each agent inside the probe sandbox with no audio server.
- **Length.** The core rules are 2048 characters or less (the documented cut of Claude Code). The whole text is 4000 characters or less.
- **`dirigible --instructions`.** A flag of the root command prints the manual, exit 0. `dirigible`, `dirigible help`, and `dirigible --help` print the help as before. The parser ignores the flag after a subcommand.
- **Prompts.** Each recipe is an MCP prompt with one required argument, `package`. `prompts/get` gives one user message: the recipe with the package path. An unknown name or no `package` gives -32602.
- **Skill.** `dirigible skill show` prints the `SKILL.md` text (frontmatter `name: dirigible` and `description`). `scripts/bundle.sh` writes it to `Contents/Resources/skills/dirigible/SKILL.md` before the signature, so the file always matches the app version. `dirigible skill path` prints the path of that file, exit 0. It exits 1 when no app holds the binary. The user links the folder into `~/.claude/skills` or `~/.agents/skills`.
- **The skill works with no MCP server.** The skill gets a table of each tool and its `dirigible` command, made from the tool table and the name rule of 0041, so a new tool shows up with no hand edit. A test fails when a tool or a command is named nowhere in the manual, the recipes, or the table, and has no exemption with a reason. Each later run keeps the manual, the recipes, and the skill current, as it keeps the guide current (user rule, 2026-10-13).
- **Copy Setup Command** does not change.

## Consequences

- A new tool or a renamed argument that the manual names fails the manual test until the text changes.
- The run that adds the long tools (run 7b) changes the recipe lines that name `dirigible level`, `loudness`, and `export` to the tools.
- A moved app gives a new path in the instructions at the next start of the server. A skill link to a moved app breaks; the guide says to link it again.
- `ParityTests` lists `skill path` and `skill show` with no tool: they read no package.

## Alternatives considered

- Typed text with tool placeholders that render a tool or a command by `Tool.all`: it switches to the long tools by itself, but each author must learn the text type.
- A committed `SKILL.md` with an equality test: a copy that each text edit must make again.
- An MCP resource for the manual: each client of the research table reads the instructions already.
- Put the manual in `dirigible --help`: the user kept `--help` for people.

## Sources

- `docs/research/agent-onboarding.md` (2026-10-13).
- Run `2026-10-13-agent-onboarding`: probes p1 (the root flag) and p2 (the instructions length), the baseline and the prototype of eval E38.
