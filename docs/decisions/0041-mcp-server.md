# 0041. MCP server: `dirigible mcp` with its own JSON-RPC layer

- Status: accepted
- Date: 2026-10-07
- Accepted: 2026-10-07, after plan gates 1 and 2 of run `2026-10-07-mcp-cli`.
- Amends: 0002 (`DirigibleCLI` also holds the MCP server), 0011 (each edit command also has an MCP tool).
- Amended: 2026-10-08, run `2026-10-08-paste-across-packages` (see 0042). `clip_paste` and `clip_paste_clips` take `source`, the absolute path of another package, with `onto`. They return a typed `ToolWork.paste` with data, not an edit closure, because a paste needs the lock and throws `PasteError`. They copy and convert with no progress and no cancel: each call runs to the end and saves, and the descriptions say so.
- Amended: 2026-10-09, run `2026-10-09-autosave-backups` (see 0043). The tools `backup_list` and `backup_revert` follow the name rule. `backup_list` reads with no lock, as `session_info`. `backup_revert` is a typed `ToolWork.revert`, because it needs the lock to read the backup.
- Amended: 2026-10-09, run `2026-10-09-chapters-export`. `chapters export` has no tool, with its reason in `ParityTests.toolExemptions`: it writes a file outside the package and edits nothing, and `session_info` gives the markers.

## Context

R16: agents such as Claude Code read and edit Dirigible sessions through MCP (Model Context Protocol). The user chose two servers with one tool set: `dirigible mcp` on package files now, and a server in the running app in Release 3. The user chose our own JSON-RPC layer over the official Swift SDK. The SDK 0.12.1 is pre-1.0, supports only the legacy protocol (2025-11-25), and adds three packages, one of them third party. The current protocol is 2026-07-28. Claude Code 2.1.292 uses it on stdio and falls back to `initialize`. Research: `.scratchpads/research-2026-10-07/mcp-server.md` (not in git) and the specification pages in Sources.

## Decision

- **Command.** `dirigible mcp` reads one JSON-RPC 2.0 message from each stdin line and writes one answer line to stdout. stdout holds only MCP messages. Log text goes to stderr. The process exits with 0 when stdin closes. Requests run one at a time, in arrival order.
- **Eras.** The server is dual era. It starts modern (2026-07-28): it answers `server/discover`, and a `_meta` protocol version other than 2026-07-28 gets error -32022 with the supported list. A modern request with no `_meta` protocol version is served, although the specification says that it must get -32602: Claude Code sends the version on each request, and a script or a test client can then send a bare request (`MCPProtocolTests.aModernRequestNeedsASupportedVersion`). An `initialize` request selects the legacy era for the life of the process, with the client version if it is 2025-11-25, 2025-06-18, or 2025-03-26, else 2025-11-25.
- **Tools.** One tool for each `dirigible` edit command, plus `session_create` and `session_info` (the JSON of `info --json`, compact, with optional `tracks` and `from`/`to` filters). The tool name is the command words with each space and hyphen replaced by `_` (`clip_ripple_delete`), so the names fit the Anthropic API pattern, which has no dot. The arguments use the option names of the command and the same defaults. Every tool takes `package`, the explicit handle: the protocol has no session. It is an absolute path, because the server and the agent can have different working folders. These commands have no tool, each with its reason in `ParityTests.toolExemptions`: `capture add` and `file add` (raw records with no audio read); `capture place`, `take finalize`, `import`, `level`, `loudness`, `peaks`, `render`, and `export` (long audio work that needs progress and cancel, Release 3); `record` (the consent sheet of the app, Release 3); `devices` and `apps` (no package); and `mcp`. Each result is one text item. A bad argument, a refused edit, a held lock, and a pending take give a result with `isError: true` and the English text of the CLI. Each `validate()` rule of a command has one owner that the command and its tool both call, so no argument stops the server. An unknown tool is JSON-RPC error -32602.
- **Guard.** An edit tool takes the package lock (0012) for its read, edit, and save, through the same function as the CLI. A package that the app has open is refused with "`<path>` is open in Dirigible." `session_info` reads with no lock, as `info` does. No tool records: recording needs the consent sheet of the app (Release 3).
- **Parity.** `ParityTests` maps each public mutating method of `DirigibleCore` to its commands. It also reads the CLI command tree and checks that each command has its tool by the name rule, or a `toolExemptions` entry with its reason.
- **Code place.** The MCP code is in `DirigibleCLI`, in files that do not import ArgumentParser and do not write to stdout. Each edit tool makes the closure `(inout Session) throws(SessionError) -> [String]`, the type that `editPackage` and `Studio.edit` run. Release 3 moves these files into a library target that the app also imports. The tool text is English only, as the CLI text (0011).

## Consequences

- Each new edit command gets a tool in the same run. `ParityTests` fails until it does.
- A tool call has no undo, the same as a CLI command. The tool descriptions say so.
- The lock guard needs a volume with `flock`. On a network volume (SMB), the server cannot see that the app has the package open, and an edit can race the app (0011).
- The JSON of `session_info` is the contract of `info --json` (0011): a removed or renamed key is a breaking change.
- We track the MCP specification ourselves. The transcript tests in `MCPProtocolTests` hold the wire format of both eras.
- The JSON of a long edited session passes the 25,000-token default limit of Claude Code. A `session_info` answer over `sessionInfoBudget` characters (`MCPCall.swift`, sized from a measure of Claude Code) is an overview: each track with its clip count, the end frame, and the marker count. The agent then reads the session in parts with `from`/`to` or `tracks`.

## Alternatives considered

- **The official Swift SDK.** Rejected: legacy era only, pre-1.0 (each minor release can break the API), and three new packages. Revisit when it supports 2026-07-28 and reaches 1.0.
- **A library target `DirigibleMCP` now.** Rejected for this slice: a public API with one consumer (0002, 0011). Release 3 adds it with the app as the second consumer.
- **A tool that runs a `dirigible` subprocess per call.** Rejected: a process for each call, text parsing of stdout, and no closure for `Studio.edit`.
- **Generate the CLI commands from the tool table, or the tools from the ArgumentParser metadata.** Rejected: the CLI help and exit codes are a contract (0011), and the metadata has no `Session` closure.
- **Dots in tool names** (`clip.ripple-delete`). Rejected: the Anthropic API tool-name pattern has no dot.

## Sources

- MCP specification 2026-07-28: versioning, `server/discover`, stdio, tools. https://modelcontextprotocol.io/specification/2026-07-28/
- Claude Code changelog, 2.1.292 and 2.1.238. https://raw.githubusercontent.com/anthropics/claude-code/main/CHANGELOG.md
- modelcontextprotocol/swift-sdk 0.12.1. https://github.com/modelcontextprotocol/swift-sdk
