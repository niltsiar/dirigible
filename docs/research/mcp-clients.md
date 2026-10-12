# Register the Dirigible MCP server in MCP clients

Date: 2026-10-12

Question: how does a user register the local stdio server `'<path>/Dirigible.app/Contents/Helpers/dirigible' mcp`, user-wide where possible, in Claude Code, Codex CLI, opencode, and a generic MCP app? Which `clientInfo.name` does each client send?

In the examples, `/Applications/Dirigible.app/Contents/Helpers/dirigible` is the path. Replace it with the real path. Each example puts the path in single quotes, so a path with spaces works.

## Summary

| Client | Command or file | User-wide file | Check | `clientInfo.name` |
|---|---|---|---|---|
| Claude Code | `claude mcp add --scope user dirigible -- '<path>' mcp` | `~/.claude.json` | `claude mcp get dirigible`, `claude mcp list`, `/mcp` | `claude-code` (probe) |
| Codex CLI | `codex mcp add dirigible -- '<path>' mcp` | `~/.codex/config.toml` | `codex mcp list`, `/mcp` | `codex-mcp-client` (source) |
| opencode | `opencode mcp add dirigible -- '<path>' mcp` | `~/.config/opencode/opencode.json` or `.jsonc` | `opencode mcp list` | `opencode` (probe) |
| Claude Desktop | `mcpServers` JSON | `~/Library/Application Support/Claude/claude_desktop_config.json` | Restart, then Connectors | Not verified |
| Cursor | `mcpServers` JSON | `~/.cursor/mcp.json` | Output panel, "MCP Logs" | Not verified |
| VS Code | `mcpServers` JSON, or `code --add-mcp` | `~/.copilot/mcp-config.json` | "MCP: List Servers" | `Visual Studio Code` (source, stable build) |

## 1. Claude Code

Command (probe: `claude mcp add --help`, Claude Code 2.1.296):

```sh
claude mcp add --scope user dirigible -- '/Applications/Dirigible.app/Contents/Helpers/dirigible' mcp
```

- Usage line: `claude mcp add [options] <name> <commandOrUrl> [args...]`. The transport is stdio when you do not give `--transport` [S1, S2].
- `--` separates the options of Claude Code from the server command. "Everything after `--` is passed to the server untouched" [S1].
- Scopes: `local` (the default, this project only), `project` (`.mcp.json` in the project root, shared through git), `user` ("available to you across all projects"). Local and user scope are stored in `~/.claude.json` [S1].
- Put `--env KEY=value` before another option, not directly before the name. Else the CLI reads the name as one more pair [S1].
- JSON form: `claude mcp add-json --scope user dirigible '{"type":"stdio","command":"/Applications/Dirigible.app/Contents/Helpers/dirigible","args":["mcp"]}'` [S1].
- Check: `claude mcp get dirigible`, or `claude mcp list`. The list shows `✔ Connected` or `✘ Failed to connect`. In a session, `/mcp` shows the status [S1]. `claude mcp list` health-checks each approved server [S2].
- Remove: `claude mcp remove dirigible` [S1]. Add `--scope user` when the name is in more than one scope.

`clientInfo` (probe P1, Claude Code 2.1.296): `{"name":"claude-code","title":"Claude Code","version":"2.1.296",...}`.

**Important:** Claude Code 2.1.296 sends `server/discover` first, before `initialize`. That request carries the client identity in `params._meta["io.modelcontextprotocol/clientInfo"]`, with the same `name`. When the server does not answer with a result, Claude Code falls back to `initialize` (P1). The MCP revision 2026-07-28 tells a dual-era client on stdio to "fall back on any error that is not a recognized modern error" [S9]. Thus a server that only does the `initialize` handshake must answer `server/discover` with a JSON-RPC error, for example `-32601` (method not found). It must not answer with `-32022` (`UnsupportedProtocolVersionError`): that error marks a modern server, and the client then does not fall back [S9]. Inference: a server that does not answer at all makes the client wait for its timeout. P1 did not measure that wait.

## 2. OpenAI Codex CLI

Command [S3]:

```sh
codex mcp add dirigible -- '/Applications/Dirigible.app/Contents/Helpers/dirigible' mcp
```

- Syntax: `codex mcp add <server-name> --env VAR1=VALUE1 -- <stdio server-command>` [S3].
- The command writes to `$CODEX_HOME/config.toml`, by default `~/.codex/config.toml`. It prints `Added global MCP server 'dirigible'.` [S3, S4].
- Project scope: `.codex/config.toml` in the project. This works only in a trusted project [S3].
- The Codex desktop app, the CLI, and the IDE extension share this file [S3].

TOML form, the same result:

```toml
[mcp_servers.dirigible]
command = "/Applications/Dirigible.app/Contents/Helpers/dirigible"
args = ["mcp"]
```

- Keys: `command` (required), `args`, `env`, `cwd`, `startup_timeout_sec` (default 10), `tool_timeout_sec` (default 60), `enabled` [S3].
- A TOML basic string (`"..."`) keeps spaces. Write a backslash as `\\`. A macOS path has no backslash.
- Check: `codex mcp list`. In the `codex` TUI, `/mcp` shows the active servers [S3].
- Remove: `codex mcp remove dirigible` prints `Removed global MCP server 'dirigible'.` [S4].

`clientInfo` (source, tag `rust-v0.162.1`): `Implementation::new("codex-mcp-client", <version>).with_title("Codex")`, with protocol version `2025-06-18` in `initialize` [S5]. Codex is not installed on this Mac, so no probe ran.

## 3. opencode

Command (source tag `v1.19.0` [S6], probe P2 with opencode 1.18.30):

```sh
opencode mcp add dirigible -- '/Applications/Dirigible.app/Contents/Helpers/dirigible' mcp
```

- With a name and a command after `--`, the command does not ask questions. It always writes to the global config [S6].
- With no name, `opencode mcp add` asks questions. In a git project, it asks for "Current project" or "Global". This interactive form splits the command at each space (`command.split(" ")`), so it breaks a path with spaces [S6]. Use the form with `--`.
- Global config: `~/.config/opencode/opencode.json` [S7]. The command writes to `opencode.json` or `opencode.jsonc`, whichever exists. In P2, it wrote `opencode.jsonc`. The command prints the path: `MCP server "dirigible" added to <path>` (P2).
- Project config: `opencode.json` in the project root [S7]. Files merge; a later source overrides an earlier one [S7].
- The docs page [S8] does not show `opencode mcp add`. The CLI help and the source have it.

JSON form, the same result (P2 output):

```json
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "dirigible": {
      "type": "local",
      "command": ["/Applications/Dirigible.app/Contents/Helpers/dirigible", "mcp"],
      "enabled": true
    }
  }
}
```

- `command` is one array: the program, then its arguments. Each element is one argument, so a space in the path needs no quotes [S8], (P2).
- Other keys: `environment`, `enabled`, `cwd`, `timeout` (milliseconds to fetch the tools, default 5000) [S8].
- Check: `opencode mcp list`. It starts the server and shows `✓` or `✗ ... failed` (P2).

`clientInfo` (P2, opencode 1.18.30): `{"name":"opencode","version":"1.18.30"}`, protocol `2025-11-25`. Source tag `v1.19.0` has `new Client({ name: "opencode", version: InstallationVersion })` [S6].

**Change on the `dev` branch:** the unreleased `dev` branch writes the server to `mcp.servers.<name>`, not `mcp.<name>`, and adds modern (2026-07-28) connections [S10]. A future release can change the JSON form above. The command form with `--` stays the same on `dev`.

## 4. A generic MCP app

Most apps read the same `mcpServers` JSON object. Give this snippet to the guide as the "any MCP app" form:

```json
{
  "mcpServers": {
    "dirigible": {
      "command": "/Applications/Dirigible.app/Contents/Helpers/dirigible",
      "args": ["mcp"]
    }
  }
}
```

The path is one JSON string, so spaces need no escape. Use an absolute path [S11].

### Claude Desktop

- File: `~/Library/Application Support/Claude/claude_desktop_config.json`. Open it with Claude menu > Settings > Developer > Edit Config [S11].
- Quit Claude Desktop completely and open it again. Then click "Add files, connectors, and more", then "Connectors", then "Manage connectors", and select the server [S11].
- Logs: `~/Library/Logs/Claude/mcp.log`, and `mcp-server-dirigible.log` for the stderr of the server [S11].
- `clientInfo`: not verified. Claude Desktop is closed source, and no probe ran.

### Cursor

- User-wide file: `~/.cursor/mcp.json`. Project file: `.cursor/mcp.json` [S12].
- The STDIO table lists `"type": "stdio"` as required, but the example omits it [S12]. Add `"type": "stdio"` for Cursor.
- Check: Output panel (Cmd+Shift+U), then "MCP Logs" [S12].
- `clientInfo`: not verified. Cursor is closed source, and no probe ran.

### VS Code (GitHub Copilot)

- Preferred user-wide file: `~/.copilot/mcp-config.json` (or `$COPILOT_HOME/mcp-config.json`), with the `mcpServers` object [S13].
- Preferred project file: `.mcp.json` in the project root, with `mcpServers`. It "works across compatible tools" [S13].
- `.vscode/mcp.json` and the user-profile `mcp.json` (top-level `servers` object) are deprecated destinations [S13].
- Command line: `code --add-mcp '{"name":"dirigible","command":"/Applications/Dirigible.app/Contents/Helpers/dirigible","args":["mcp"]}'` [S13]. The docs do not say which file it writes.
- Check: "MCP: List Servers", select the server, then "Show Output" [S13].
- `clientInfo` (source): `name: productService.nameLong` [S14]. Inference: that is `Visual Studio Code` in the stable build and `Visual Studio Code - Insiders` in Insiders. The `product.json` of Microsoft builds was not read.

## clientInfo for an Undo label

| Client | `name` | `title` | Evidence |
|---|---|---|---|
| Claude Code | `claude-code` | `Claude Code` | P1 |
| Codex CLI | `codex-mcp-client` | `Codex` | S5 |
| opencode | `opencode` | none | P2, S6 |
| VS Code | `Visual Studio Code` | none | S14, inference for the value |
| Claude Desktop | not verified | | |
| Cursor | not verified | | |

- Prefer `title` when it is there, then `name`. Codex shows why: its `name` is `codex-mcp-client`, its `title` is `Codex`.
- In a modern (2026-07-28) request, the identity is in `params._meta["io.modelcontextprotocol/clientInfo"]`, not in `initialize` [S9], (P1).
- `clientInfo` is text that the client chooses. Treat it as untrusted input at the boundary: limit its length and keep a fallback label for a missing value.

## Open questions

- Claude Desktop and Cursor `clientInfo`: run the P1 logger as their server and read `init-<name>.jsonl`.
- How long does Claude Code wait when a legacy server sends no reply to `server/discover`? The answer tells if an error reply is required or only faster.
- Codex was not probed. Install it and run P1 to confirm `codex-mcp-client`.

## Probes

The probe folder is `.scratchpads/probe-mcp-clientinfo/`. `dir with space/logger.sh <label>` reads one line from stdin, appends it to `init-<label>.jsonl`, and exits.

- P1: `scripts/probe.sh . bash run-claude.sh` runs `claude -p --strict-mcp-config --mcp-config claude-mcp.json --model haiku "Reply with the word ok."`. The server path has a space. Output: `dir with space/init-claude-code.jsonl` (a `server/discover` line, then an `initialize` line).
- P2: `scripts/probe.sh . bash run-opencode.sh` runs `opencode mcp list` with a project `opencode.json`, with `HOME` and the XDG folders in the probe folder. Output: `dir with space/init-opencode.jsonl`. `run-opencode-add.sh` runs `opencode mcp add dirigible -- "/Applications/Dirigible Copy.app/Contents/Helpers/dirigible" mcp` and prints the file that it writes.

## Sources

- S1: Claude Code docs, "Connect Claude Code to tools via MCP", https://code.claude.com/docs/en/mcp (read 2026-10-12, no page date)
- S2: `claude mcp add --help` and `claude mcp list --help`, Claude Code 2.1.296 (run 2026-10-12)
- S3: OpenAI Codex docs, MCP, https://learn.chatgpt.com/docs/extend/mcp?surface=cli (redirect from https://developers.openai.com/codex/mcp; read 2026-10-12, no page date)
- S4: openai/codex `codex-rs/cli/src/mcp_cmd.rs`, tag `rust-v0.162.1` (2026-10-09), https://github.com/openai/codex/blob/rust-v0.162.1/codex-rs/cli/src/mcp_cmd.rs
- S5: openai/codex `codex-rs/codex-mcp/src/rmcp_client.rs` line 1126, tag `rust-v0.162.1` (2026-10-09), https://github.com/openai/codex/blob/rust-v0.162.1/codex-rs/codex-mcp/src/rmcp_client.rs
- S6: anomalyco/opencode (was sst/opencode) `packages/opencode/src/cli/cmd/mcp.ts` and `packages/opencode/src/mcp/index.ts` line 76, tag `v1.19.0` (2026-10-11), https://github.com/anomalyco/opencode/blob/v1.19.0/packages/opencode/src/cli/cmd/mcp.ts
- S7: opencode docs, Config, https://opencode.ai/docs/config/ (last updated 2026-10-12)
- S8: opencode docs, MCP servers, https://opencode.ai/docs/mcp-servers/ (last updated 2026-10-12)
- S9: MCP specification 2026-07-28, Versioning and Compatibility, https://modelcontextprotocol.io/specification/2026-07-28/basic/lifecycle (read 2026-10-12)
- S10: anomalyco/opencode `packages/cli/src/commands/handlers/mcp/add.ts` and `packages/schema/src/config/mcp.ts`, branch `dev` (read 2026-10-12), https://github.com/anomalyco/opencode/tree/dev/packages
- S11: MCP docs, "Connect to local MCP servers", https://modelcontextprotocol.io/docs/develop/connect-local-servers (read 2026-10-12, no page date)
- S12: Cursor docs, MCP, https://cursor.com/docs/context/mcp (read 2026-10-12, no page date)
- S13: VS Code docs, "Add and manage MCP servers in VS Code", https://code.visualstudio.com/docs/copilot/customization/mcp-servers (page date 2026-10-07)
- S14: microsoft/vscode `src/vs/workbench/contrib/mcp/common/mcpServerRequestHandler.ts` lines 135-138, branch `main` (read 2026-10-12), https://github.com/microsoft/vscode/blob/main/src/vs/workbench/contrib/mcp/common/mcpServerRequestHandler.ts
