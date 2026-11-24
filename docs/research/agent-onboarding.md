# Teach an agent to use the Dirigible MCP server

Date: 2026-10-13

Question: which channels can teach an agent to use `dirigible mcp`? The channels are the server `instructions`, MCP prompts, MCP resources, and Agent Skills. Which clients read each channel: Claude Code, Codex CLI, opencode, Claude Desktop, and Cursor? Which ideas from Showboat, Rodney, and Hunk fit an MCP server for a desktop app?

`docs/research/mcp-clients.md` has the registration facts and the `clientInfo` values. This file does not repeat them.

Local versions: Claude Code 2.1.296, opencode 1.18.30. Codex is not installed. Source reads use Codex `main` at commit `044e74fe` (2026-10-13) and opencode tag `v1.19.0`. The Codex release tags were not checked against this commit.

## State of Dirigible today

State on 2026-11-24 (decision 0051): `Sources/DirigibleMCP/MCPServer.swift` sends `instructions` in the `server/discover` result and in the `initialize` result. The text comes from `AgentManual`.

- The `capabilities` object has `tools` and `prompts`. Each recipe is a prompt. The server has no `resources` capability. Each other method gets `-32601`.
- On 2026-10-13, the server sent no `instructions` and no `prompts`. The rest of this note was written from that state.

## 1. Server `instructions`

### The spec

- Legacy era (2025-11-25 and earlier): `InitializeResult.instructions` is an optional string. "This can be used by clients to improve the LLM's understanding of available tools, resources, etc. ... this information MAY be added to the system prompt." [S1]
- Modern era (2026-07-28): the `server/discover` result carries `instructions`: "Optional natural-language guidance for LLMs on how to use this server effectively". The example puts it at the top level of the result, next to `supportedVersions` and `capabilities` [S2].
- Thus a dual-era server sends the same text in two places: in the `server/discover` result and in the `initialize` result.

### Claude Code

- Claude Code reads `instructions` in both eras (probe P3, Claude Code 2.1.296). The model quoted the codeword of the modern server (from `server/discover`) and the codeword of the legacy server (from `initialize`) verbatim.
- With tool search, "Only tool names and server instructions load at session start" [S3].
- Limit: "Claude Code truncates each tool description and each server's instructions at 2,048 characters by default. Keep them concise, and put critical details near the start." [S3]
- The variable `CLAUDE_CODE_MAX_MCP_DESCRIPTION_LENGTH` changes the limit for every server in the session. It needs v2.1.280 or later [S3]. Inference: a server cannot rely on it, because the user sets it.
- The docs tell the server author to say what tasks the tools handle, when Claude must search for the tools, and the key capabilities [S3].

### Codex CLI

- Codex reads `initialize_result.instructions` and keeps it as `server_instructions` [S4].
- For a regular MCP server, the instructions become the `namespace_description` of each tool of the server [S4]. Codex sends the namespace with its description to the model as a Responses API tool namespace [S5]. The tool search text also includes it [S5].
- Limit: `MAX_MCP_NAMESPACE_DESCRIPTION_BYTES` is 512 KiB. For an agent-plugin server, the limit is 1,000 bytes [S5].
- Codex uses the legacy `initialize` handshake by default. The modern 2026-07-28 lifecycle is behind the feature `mcp_2026_07_28`, stage "UnderDevelopment", `default_enabled: false` [S6]. Thus today Codex reads the `initialize` copy only.
- Inference: Codex puts the instructions in the tool namespace, not in the system prompt. The model sees them next to the tools, not as a separate block.

### opencode

- opencode stores `mcpClient.getInstructions()` for each connected server [S7].
- The system prompt gets an `<mcp_instructions>` block with one `<server name="...">` element for each server [S8]. A server whose tools are all disabled for the agent is left out [S8].
- The source has no truncation of the instructions [S7, S8].
- opencode 1.18.30 sends protocol `2025-11-25` in `initialize` (mcp-clients.md, P2). Thus it reads the `initialize` copy. The unreleased `dev` branch adds modern connections (mcp-clients.md, S10).

### Claude Desktop

- Not verified. The Claude connector docs list tools, prompts, and resources, but say nothing about `instructions` [S9]. Claude Desktop is closed source, and no probe ran.

### Cursor

- Partial. The Cursor MCP docs list no `instructions` feature [S10].
- The Cursor CLI changelog v2026.06.29 says: "Working servers no longer appear disconnected in `/mcp` and `agent mcp list` when their tools or instructions are available." [S11]
- Inference: the Cursor CLI reads `instructions`. The changelog does not say that the editor puts them in the model context.

## 2. MCP prompts

The spec says that prompts are "user-controlled": the user selects them explicitly [S12]. A server declares the `prompts` capability and answers `prompts/list` and `prompts/get` [S12].

| Client | Support | How the user calls a prompt |
|---|---|---|
| Claude Code | Yes [S3] | Type `/`. The menu shows `/servername:promptname (MCP)`. `/mcp__servername__promptname` also runs it. Arguments follow, separated by spaces. Each argument is one token. The result goes into the conversation [S3]. |
| Codex CLI | No | The source has no `prompts/list` and no `prompts/get` call [S4]. |
| opencode | Yes [S13] | Each prompt becomes a command named `<server>:<prompt>`, with each character outside `[a-zA-Z0-9_-]` changed to `_` [S13, S14]. Arguments map to `$1`, `$2`, and so on [S13]. |
| Claude Desktop | Partial | The MCP guide for a remote server says: click "Add files, connectors, and more", then "Connectors", then "Add to <server>". The menu shows the prompts and resources of the server [S15]. Inference: a local stdio server gets the same menu. No source says so for a local server. |
| Cursor | Yes, per the feature table [S10] | The docs do not say how the user calls a prompt [S10]. |

- Claude Code hides the prompts of a server named `anthropic-skills` [S3]. Dirigible does not use that name.
- Claude Code sends `prompts/list` only when the server declares the capability. In P3, a server with only `tools` got `server/discover` and `tools/list` and nothing more.

## 3. Agent Skills

### The format (agentskills.io)

- A skill is a folder with a `SKILL.md` file. Optional subfolders are `scripts/`, `references/`, and `assets/` [S16].
- `name`: required, 1-64 characters, lowercase `a-z`, `0-9`, and `-`. It must not start or end with `-`, must not have `--`, and must match the parent folder name [S16].
- `description`: required, 1-1024 characters. It says what the skill does and when to use it [S16].
- Optional: `license`, `compatibility` (1-500 characters), `metadata` (string to string map), `allowed-tools` (experimental) [S16].
- Agents load `name` and `description` at startup (about 100 tokens). They load the body when the skill activates. Keep the body under 5,000 tokens and under 500 lines [S16].

Claude Code differences [S17]:

- `name` is optional. It defaults to the folder name.
- The skill listing truncates `description` plus `when_to_use` at 1,536 characters. "Put the key use case first".

### Where each client reads skills

| Client | Folders | Arbitrary path or symlink |
|---|---|---|
| Claude Code | Personal `~/.claude/skills/<name>/SKILL.md`. Project `.claude/skills/` in the start folder and each parent up to the repo root. Enterprise (managed settings folder). Plugin `<plugin>/skills/<name>/SKILL.md`. `.claude/skills/` in a `--add-dir` folder [S17]. | A `<skill-name>` entry in the personal, project, or enterprise location "can be a symlink to a directory elsewhere on disk" [S17]. `--plugin-dir <path>` loads a plugin folder or `.zip` for one session (`claude --help`, 2.1.296). |
| Codex CLI | Repo `.agents/skills` from the cwd up to the repo root. User `~/.agents/skills`. Admin `/etc/codex/skills`. System (bundled) [S18]. The source also reads `$CODEX_HOME/skills` (`~/.codex/skills`) as a "Deprecated user skills location", and `.codex/skills` of a project config layer [S19]. | "Codex supports symlinked skill folders and follows the symlink target" [S18]. No config key adds a path. `[[skills.config]]` only turns a skill off [S18]. Extra roots come only from the app-server request `skills/extraRoots/set`, which a host app sends [S20]. |
| opencode | `.opencode/skills/`, `~/.config/opencode/skills/`, `.claude/skills/`, `~/.claude/skills/`, `.agents/skills/`, `~/.agents/skills/` [S21]. Project folders walk up to the git worktree [S21]. | The config key `skills.paths` adds folders, absolute or with `~/` [S22]. `skills.urls` pulls skills from a URL [S22]. The scan follows symlinks (`symlink: true`) [S22]. |
| Cursor | `.agents/skills/`, `.cursor/skills/`, `~/.agents/skills/`, `~/.cursor/skills/`. Also `.claude/skills/`, `.codex/skills/`, `~/.claude/skills/`, `~/.codex/skills/` [S23]. | CLI v2026.06.22: "The skills menu follows symlinked directories when discovering skills." [S11] |
| Claude Desktop | No folder. The user uploads a ZIP: Customize > Skills > "+" > "+ Create skill" > "Upload a skill". The ZIP holds the skill folder. The folder name must match the skill name [S24]. In a deployment on a third-party platform, admins can ship skills in plugins in `/Library/Application Support/Claude/org-plugins/` [S25]. | Upload only. Inference: a skill in the app bundle needs a ZIP export for this client. |

- Inference: `~/.agents/skills/<name>` is the one user folder that Codex, opencode, and Cursor all read. Claude Code does not read it. `~/.claude/skills/<name>` is read by Claude Code, opencode, and Cursor, but not by Codex. Thus a user who has Claude Code and Codex needs two links.
- Inference: a symlink from `~/.claude/skills/dirigible` or `~/.agents/skills/dirigible` to a folder in `Dirigible.app` works in Claude Code, Codex, opencode, and Cursor. When the app moves or is deleted, the link breaks. A copy does not break, but it gets old when the app updates.
- Hunk solves the version problem with a pointer skill (section 5).

## 4. MCP resources

The spec says that resources are "application-driven": the host decides how to use them [S26]. A server declares `resources` and answers `resources/list` and `resources/read` [S26].

| Client | Support | How the content reaches the model |
|---|---|---|
| Claude Code | Yes [S3] | The user types `@server:protocol://path`. Claude Code fetches the resource and attaches it. Claude Code also gives the model tools to list and read resources [S3]. |
| Codex CLI | Yes [S27] | Model tools `list_mcp_resources`, `list_mcp_resource_templates`, and `read_mcp_resource` [S27]. |
| opencode | Yes [S13, S28] | Model tools `list_mcp_resources`, `list_mcp_resource_templates`, `read_mcp_resource` [S28]. A resource part in a user message is read and put in the message [S29]. |
| Claude Desktop | Partial | The attachment menu of a remote server [S15]. The connector docs list text and binary resources as supported, and resource subscriptions as not supported [S9]. A local stdio server was not checked. |
| Cursor | Yes, per the feature table [S10] | The docs do not say how [S10]. |

Is a resource a fit for the manual?

- Inference: yes as a second copy, not as the only channel. Each client except Claude Desktop gives the model a tool to read a resource. But the model reads a resource only when something tells it to. The 2,048-character `instructions` can say "read `dirigible://manual` before the first call".
- Inference: a resource comes from the running binary, so it always matches the installed version. A skill file on disk can be old.
- Inference: a manual as a tool result (for example a `help` tool) reaches every client that has tools, also Claude Desktop. A resource adds the `@` mention in Claude Code and opencode.

## 5. Outside tools

### Showboat and Rodney (Simon Willison, 2026-02-10) [S30]

- `--help` is the manual for the agent. Showboat's `--help` "is designed to provide a coding agent with everything it needs to know in order to use the tool". Rodney follows the same pattern: agents "run `rodney --help` and see everything they need to know to start using the tool".
- The prompt is short: "run `uvx showboat --help`", then do the task. The tool, not the prompt, holds the instructions.
- Captured output instead of claims: `showboat exec` runs a command and writes its real output into the document after the command. `showboat image` copies an image that the command made. `verify` runs the document again and compares.
- Limit: the agent "will sometimes edit that file directly rather than using Showboat". Thus the record is not proof against an agent that cheats.
- Rodney keeps one browser session across separate commands (`start`, `stop`).

Ideas that fit a desktop-app MCP server (Inference for each). Built: decision 0051 holds the one entry point (`dirigible --instructions`, the `instructions` field, and the prompts).

- Make one entry point that teaches everything: `dirigible --help` and `dirigible mcp --help` for the CLI, and the same text in the MCP `instructions` and in a help tool or resource.
- Make each tool result show what happened (the state after the change), so the agent reports output, not a claim.
- Keep the session state in the app, as Rodney keeps the browser. The agent sends short separate calls.

### Hunk (modem-dev/hunk, commit `6aa52617`, 2026-10-13) [S31]

- The README tells the user: open Hunk in a terminal, "Tell your agent to add the skill file returned by `hunk skill path`", then ask the agent to use the skill. The suggested prompt is "Load the Hunk skill and use it for this review. Run `hunk skill path` to get the skill path." [S31]
- `hunk skill path [name]` prints the path of the `SKILL.md` that ships with the installed binary. `hunk skill show [name]` prints the full text [S32]. The help says: `show` is "for agents that load instructions on demand", and `path` is "for agents that load or symlink files" [S32].
- The binary finds the file at `skills/<name>/SKILL.md` relative to its own location, in the source, npm, and prebuilt layouts [S33]. Two skills ship: `hunk-review` (the default) and `hunk-extensions`, with short aliases [S33].
- Repo layout: `packages/hunk/skills/<name>/SKILL.md` holds the full skill (223 lines for `hunk-review`). `package.json` `files` ships only these folders [S34]. The root `skills/` folder holds maintainer skills that never ship [S33].
- `.agents/skills/<name>/SKILL.md` is a generated pointer skill with the same frontmatter. Its body says: "This file is a pointer. The instructions live in the installed `hunk` CLI so they always match its version." Then it tells the agent to run `hunk skill show hunk-review` [S35]. `npx skills add modem-dev/hunk` installs this pointer [S32].
- The full skill starts with a boundary: "The TUI is for the user -- do NOT run `hunk diff`, `hunk show`, or other interactive commands directly." The agent uses `hunk session *` commands, which talk to a local daemon of the live window [S34, S36].
- Output modes: in a terminal, `hunk status` opens an interactive view. `--static` prints one text snapshot. `--json` prints one JSON object with `schemaVersion: 1`, with no color and no pager. A redirect selects static output by itself. Errors go to stderr with a nonzero exit, also with `--json` [S37].
- The workflow asks for `review --json` first and the raw patch only with `--include-patch` [S34]. Thus the agent gets the structure before the large text.

Ideas that fit Dirigible (Inference for each). Built: `dirigible skill path` and `dirigible skill show` (`Sources/DirigibleCLI/SkillCommand.swift`, decision 0051). The bundle holds one skill text.

- Ship `SKILL.md` in the app bundle, and add `dirigible skill path` and `dirigible skill show`. The user links or copies the folder that `skill path` prints.
- Ship a pointer skill for the skill folders: a short `SKILL.md` that says "run `dirigible skill show`". The pointer never gets old, because the text comes from the installed binary. A link to the bundle also stays current, but it breaks when the app moves.
- Put a boundary in the skill: the window is for the user, and the agent uses the MCP tools or the CLI.
- Give each read command a `--json` form with a `schemaVersion`, and a plain text form when stdout is not a terminal.
- Return a summary first and large data only on request.

## Summary table

Yes, No, or Partial, with the source ID. "Skills folder" means that the client reads `SKILL.md` from a folder on disk.

| Client | `instructions` | Prompts | Resources | Skills folder |
|---|---|---|---|---|
| Claude Code | Yes, both eras, 2,048 characters (S3, P3) | Yes, `/server:prompt` (S3) | Yes, `@` and model tools (S3) | Yes, `~/.claude/skills`, symlink OK (S17) |
| Codex CLI | Yes, `initialize` only, as tool namespace text (S4, S5, S6) | No (S4) | Yes, model tools (S27) | Yes, `~/.agents/skills`, symlink OK (S18, S19) |
| opencode | Yes, `initialize`, in the system prompt (S7, S8) | Yes, `server:prompt` command (S13) | Yes, model tools and `@` (S28, S29) | Yes, six folders and `skills.paths` (S21, S22) |
| Claude Desktop | Not verified (S9) | Partial, remote-server guide (S15) | Partial, remote-server guide (S9, S15) | No, ZIP upload only (S24) |
| Cursor | Partial, CLI changelog (S11) | Yes, feature table (S10) | Yes, feature table (S10) | Yes, eight folders, symlink OK (S11, S23) |

## Open questions

- Claude Desktop: does it read `instructions`, and does a local stdio server get the prompts and resources menu? Run the P3 server in Claude Desktop and ask the same question.
- Cursor editor: does it put `instructions` in the model context? Run P3 with `cursor-agent` or the editor.
- Codex: confirm that the instructions reach the model with Codex installed. Run P3 with `codex exec`.
- Claude Code: P3 did not test the 2,048-character limit. The docs state it [S3].
- Related to mcp-clients.md: the Claude hosted surfaces send `clientInfo.name` `claude-ai` or `Anthropic`, "sometimes with a service suffix" [S38]. This is not Claude Desktop with a local server, which stays not verified.

## Probes

- P3: local run folder `probe-mcp-instructions`, not in git. `fake_server.py <mode> <codeword> <log>` is a fake stdio MCP server with one `noop` tool. In `modern` mode, it answers `server/discover` with `instructions`. In `legacy` mode, it answers `server/discover` with `-32601`, and `initialize` with `instructions`. `scripts/probe.sh <run folder> bash run.sh` runs `claude -p --strict-mcp-config --mcp-config mcp.json --model haiku` with the servers `probe-modern` (codeword `PELICAN-MODERN-7`) and `probe-legacy` (codeword `HERON-LEGACY-3`). It asks the model to quote the instructions of each server, or to write NONE.
- P3 result (Claude Code 2.1.296, 2026-10-13): the answer quoted `Codeword for this server: PELICAN-MODERN-7.` and `Codeword for this server: HERON-LEGACY-3.`. `log-modern.jsonl` holds `server/discover`, then `tools/list` with modern `_meta`. `log-legacy.jsonl` holds `server/discover`, `initialize` (protocol `2025-11-25`), `notifications/initialized`, and `tools/list`.

## Sources

- S1: MCP schema 2025-11-25, `InitializeResult.instructions`, https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/schema/2025-11-25/schema.ts (read 2026-10-13)
- S2: MCP specification 2026-07-28, Discovery, https://modelcontextprotocol.io/specification/2026-07-28/server/discover (read 2026-10-13)
- S3: Claude Code docs, "Connect Claude Code to tools via MCP", sections "Use MCP resources", "Tool search for MCP server authors", "Use MCP prompts as commands", https://code.claude.com/docs/en/mcp (read 2026-10-13, no page date)
- S4: openai/codex `codex-rs/codex-mcp/src/rmcp_client.rs` lines 800-870 and 1005-1075, commit `044e74fe` (2026-10-13), https://github.com/openai/codex/blob/044e74fef3d1af2b01f4375158ac1e7ad4ae17ea/codex-rs/codex-mcp/src/rmcp_client.rs (read 2026-10-13)
- S5: openai/codex `codex-rs/core/src/tools/handlers/mcp.rs` lines 48-49, 155-175, 505-600, commit `044e74fe`, https://github.com/openai/codex/blob/044e74fef3d1af2b01f4375158ac1e7ad4ae17ea/codex-rs/core/src/tools/handlers/mcp.rs (read 2026-10-13)
- S6: openai/codex `codex-rs/rmcp-client/src/protocol_mode.rs` and `codex-rs/features/src/lib.rs` (feature `mcp_2026_07_28`), commit `044e74fe`, https://github.com/openai/codex/blob/044e74fef3d1af2b01f4375158ac1e7ad4ae17ea/codex-rs/features/src/lib.rs (read 2026-10-13)
- S7: anomalyco/opencode `packages/opencode/src/mcp/index.ts` lines 399, 524, 615-625, tag `v1.19.0` (2026-10-11), https://github.com/anomalyco/opencode/blob/v1.19.0/packages/opencode/src/mcp/index.ts (read 2026-10-13)
- S8: anomalyco/opencode `packages/opencode/src/session/system.ts` lines 121-137, tag `v1.19.0`, https://github.com/anomalyco/opencode/blob/v1.19.0/packages/opencode/src/session/system.ts (read 2026-10-13)
- S9: Claude docs, "Build an MCP server for Claude", section "Decide what the server exposes", https://claude.com/docs/connectors/building/index (read 2026-10-13, no page date)
- S10: Cursor docs, MCP, feature table, https://cursor.com/docs/context/mcp and its Markdown form https://cursor.com/docs/mcp.md (read 2026-10-13, no page date)
- S11: Cursor CLI changelog, entries v2026.06.29 and v2026.06.22, https://cursor.com/docs/cli/changelog (read 2026-10-13)
- S12: MCP specification 2026-07-28, Prompts, https://modelcontextprotocol.io/specification/2026-07-28/server/prompts (read 2026-10-13)
- S13: anomalyco/opencode `packages/opencode/src/command/index.ts` lines 104-130, tag `v1.19.0`, https://github.com/anomalyco/opencode/blob/v1.19.0/packages/opencode/src/command/index.ts (read 2026-10-13)
- S14: anomalyco/opencode `packages/opencode/src/mcp/catalog.ts` lines 100-141, tag `v1.19.0`, https://github.com/anomalyco/opencode/blob/v1.19.0/packages/opencode/src/mcp/catalog.ts (read 2026-10-13)
- S15: MCP docs, "Connect to remote MCP servers", step "Access Resources and Prompts", https://modelcontextprotocol.io/docs/2026-07-28/develop/connect-remote-servers (read 2026-10-13)
- S16: Agent Skills specification, https://agentskills.io/specification (read 2026-10-13, no page date)
- S17: Claude Code docs, "Extend Claude with skills", sections "Where skills live" and "Frontmatter reference", https://code.claude.com/docs/en/skills (read 2026-10-13, no page date)
- S18: OpenAI Codex docs, "Build skills", https://learn.chatgpt.com/docs/build-skills (redirect from https://developers.openai.com/codex/skills; read 2026-10-13, no page date)
- S19: openai/codex `codex-rs/ext/skills/src/host_roots.rs` lines 55-125 and `codex-rs/skills/src/parser.rs` (`MAX_NAME_LEN` 64), commit `044e74fe`, https://github.com/openai/codex/blob/044e74fef3d1af2b01f4375158ac1e7ad4ae17ea/codex-rs/ext/skills/src/host_roots.rs (read 2026-10-13)
- S20: openai/codex `codex-rs/app-server/src/request_processors/catalog_processor.rs` lines 594-606, commit `044e74fe`, https://github.com/openai/codex/blob/044e74fef3d1af2b01f4375158ac1e7ad4ae17ea/codex-rs/app-server/src/request_processors/catalog_processor.rs (read 2026-10-13)
- S21: opencode docs, "Agent Skills", source `packages/web/src/content/docs/skills.mdx` at tag `v1.19.0`, https://opencode.ai/docs/skills/ (read 2026-10-13)
- S22: anomalyco/opencode `packages/opencode/src/skill/index.ts` lines 21-25, 142-160, 205-230, tag `v1.19.0`, https://github.com/anomalyco/opencode/blob/v1.19.0/packages/opencode/src/skill/index.ts (read 2026-10-13)
- S23: Cursor docs, Skills, https://cursor.com/docs/skills (read 2026-10-13, no page date)
- S24: Claude Help Center, "Use skills in Claude", https://support.claude.com/en/articles/12512180-use-skills-in-claude (read 2026-10-13, "Updated over 3 weeks ago")
- S25: Claude docs, "MCP, plugins, skills, and hooks" (Claude Desktop on third-party platforms), https://claude.com/docs/third-party/claude-desktop/extensions (read 2026-10-13, no page date)
- S26: MCP specification 2026-07-28, Resources, https://modelcontextprotocol.io/specification/2026-07-28/server/resources (read 2026-10-13)
- S27: openai/codex `codex-rs/core/src/tools/handlers/mcp_resource/` (`list_mcp_resources.rs`, `list_mcp_resource_templates.rs`, `read_mcp_resource.rs`), commit `044e74fe`, https://github.com/openai/codex/tree/044e74fef3d1af2b01f4375158ac1e7ad4ae17ea/codex-rs/core/src/tools/handlers/mcp_resource (read 2026-10-13)
- S28: anomalyco/opencode `packages/opencode/src/session/tools.ts` lines 27-31 and 330-360, tag `v1.19.0`, https://github.com/anomalyco/opencode/blob/v1.19.0/packages/opencode/src/session/tools.ts (read 2026-10-13)
- S29: anomalyco/opencode `packages/opencode/src/session/prompt.ts` lines 700-725, tag `v1.19.0`, https://github.com/anomalyco/opencode/blob/v1.19.0/packages/opencode/src/session/prompt.ts (read 2026-10-13)
- S30: Simon Willison, "Introducing Showboat and Rodney, so agents can demo what they've built", 2026-02-10, https://simonwillison.net/2026/Feb/10/showboat-and-rodney/ (read 2026-10-13)
- S31: modem-dev/hunk `README.md`, section "Working with agents", commit `6aa52617` (2026-10-13), https://github.com/modem-dev/hunk/blob/6aa526175e6b032522e92daafdfef28751d9a001/README.md (read 2026-10-13)
- S32: modem-dev/hunk `packages/hunk/src/app/cli.ts` lines 413-424 and 706-735, commit `6aa52617`, https://github.com/modem-dev/hunk/blob/6aa526175e6b032522e92daafdfef28751d9a001/packages/hunk/src/app/cli.ts (read 2026-10-13)
- S33: modem-dev/hunk `packages/hunk/src/core/run/paths.ts` lines 1-30 and 124-160, commit `6aa52617`, https://github.com/modem-dev/hunk/blob/6aa526175e6b032522e92daafdfef28751d9a001/packages/hunk/src/core/run/paths.ts (read 2026-10-13)
- S34: modem-dev/hunk `packages/hunk/skills/hunk-review/SKILL.md` and `packages/hunk/package.json` (`files`), commit `6aa52617`, https://github.com/modem-dev/hunk/blob/6aa526175e6b032522e92daafdfef28751d9a001/packages/hunk/skills/hunk-review/SKILL.md (read 2026-10-13)
- S35: modem-dev/hunk `.agents/skills/hunk-review/SKILL.md`, commit `6aa52617`, https://github.com/modem-dev/hunk/blob/6aa526175e6b032522e92daafdfef28751d9a001/.agents/skills/hunk-review/SKILL.md (read 2026-10-13)
- S36: modem-dev/hunk `docs/agent-workflows.md`, commit `6aa52617`, https://github.com/modem-dev/hunk/blob/6aa526175e6b032522e92daafdfef28751d9a001/docs/agent-workflows.md (read 2026-10-13)
- S37: modem-dev/hunk `docs/status.md`, commit `6aa52617`, https://github.com/modem-dev/hunk/blob/6aa526175e6b032522e92daafdfef28751d9a001/docs/status.md (read 2026-10-13)
- S38: Claude docs, "Test your connector", https://claude.com/docs/connectors/building/testing (read 2026-10-13, no page date)
