# 0046. MCP server in the running app: a Unix socket, the `dirigible mcp` bridge, and `AgentServer`

- Status: draft (run `2026-10-12-mcp-in-app`; accepted after its plan gate)
- Date: 2026-10-12
- Amends: 0041 (the library target `DirigibleMCP`; a call on a package that the app has open runs in the app; the tool description text about undo), 0002 (a new library target and test target).

## Context

R16 and Release 3 run 6: when the user turns it on, an agent edits a session that the app has open, and each edit is one undo step in the app. 0041 refuses a package that the app has open, and says that Release 3 moves the MCP files into a library that the app imports. MCP clients such as Claude Code, Codex, and opencode start a local server over stdio; Claude Code has stdio and HTTP only [S26]. `Studio` is `@MainActor`. Claude Code sends `clientInfo` with `title` "Claude Code" on each modern request (run 2026-10-07-mcp-cli, probe u2). Research: `.scratchpads/research-2026-10-07/mcp-server.md` section 6.3 (not in git). Design: `.scratchpads/runs/2026-10-12-mcp-in-app/design.md`.

## Decision

- **Library.** A library target `DirigibleMCP` (Foundation, `DirigibleCore`, `DirigibleAudio`) holds the protocol, the tool table, the file executor, the live executor, `AgentServer`, and the bridge client. `DirigibleCLI` keeps ArgumentParser and the stdin loop. `DirigibleApp` keeps only the wiring. The tool text stays English only (0011).
- **Transport.** The app listens on a Unix domain socket, `~/Library/Application Support/Dirigible/mcp.sock`, mode 0600, in a folder with mode 0700. `dirigible mcp` is the bridge: it stays the MCP server on stdio, keeps the era and `clientInfo`, and answers `server/discover`, `initialize`, `tools/list`, and `ping` itself. It connects to the socket at start and again before a call when it has no connection. It sends each `tools/call` to the app as one JSON line with the agent name. The app replies with the result, or with "not open" when no window has the package. With "not open", no socket, or a refused connect, the bridge runs the call on the files, as 0041 says. A connection that closes after the bridge sent a call gives an error result, and the bridge never runs that call again. A reply waits 30 s or less; at the limit the bridge closes the connection, so a late reply never answers the next call, and the next call connects again. Before a send, EPIPE or POLLHUP means no connection: the bridge connects again once. The app and the bridge read the socket path from `DIRIGIBLE_MCP_SOCKET` when it is set (the verify copy and the tests), else the default.
- **Life cycle.** The server belongs to the process and the Settings switch, not to the windows. It is off by default. On: take an `flock` on `mcp.sock.lock` beside the socket; with the lock held, another app copy serves, so this copy does not listen and Settings says so; with the lock free, remove an old socket file, bind, and listen. A path of 104 bytes or more fails (`sun_path`). Off and quit: close the listener and remove the socket file first; each connection answers its running call, then closes; release the lock last. Quit stops the server after the synchronous cancel gates of `applicationShouldTerminate` and just before the window settle; a cancelled Quit starts it again when the switch is On. While the app terminates, every window refuses agent edits as busy, so an edit that gets OK is on disk before the app ends. A crash frees the lock, and the next start replaces the socket file. With zero windows, the server listens, and each call runs on the files.
- **Owners.** `AgentListener` (`DirigibleMCP`, confined to one serial queue) owns the lock fd, the listener fd, the socket file, and the connections. It reads each fd with a `DispatchSourceRead` on that queue: no `accept` or `read` runs in a `Task`, on the cooperative pool, or on the main actor. Each accepted fd has `SO_NOSIGPIPE`, so a peer that closes cannot end the app. The queue computes `packageIdentity` of the `package` argument, so the main actor does no file system I/O for an agent call. Each connection runs one call at a time, in arrival order: its read source is suspended while its call runs and resumed after the reply write. `AgentServer` (`@MainActor @Observable`) is the face for the app: `start()`, `stop()`, `state`, and `connected`, which the views observe. Each call hops to the main actor with the resolved URL and finds its target among the `AgentTarget` values (a studio and a `busy` flag) of a closure of the app. The app sets `busy` for a window that is not open or that has a user drag in progress, so an agent edit never joins the undo step of a drag. The main actor never waits for the queue. The bridge state (the era, `clientInfo`) belongs to the `MCPServer` value of the bridge process.
- **Live tools.** `.edit` kinds run in `Studio.edit(ripple:agent:)`: one undo entry and one autosave; `Studio.checkIdle` also refuses while the studio settles (a close or Quit), so an edit that gets OK is on disk before the window closes. `.busy` and `.rippleBlocked` give `isError: true` with the CLI text. A non-ripple edit under a pending take runs, as in the app. `session_info`, `episode_get`, and `backup_list` read the studio. `marker_set` and `episode_set` with no file path run live in one `Studio.edit`: the marker part and the episode change are split out of `MarkerWork` and `EpisodeWork`, so both paths run the same code. Paste across packages, `backup_revert`, and an image or artwork argument give `isError: true`: "`<path>` is open in Dirigible. Do this in the app, or close the window."
- **Protocol fallback.** The bridge answers an unknown method, and `server/discover` in the legacy era, with -32601, never -32022, so a dual-era client falls back to `initialize`.
- **Agent name.** `AgentName` (`DirigibleCore`) is the `clientInfo` title; else the display name of a known client ID (`claude-code`, `codex-mcp-client`, `opencode`); else the raw name: trimmed, 1 to 40 characters, no control characters; else "Agent". Each `History` entry keeps its `AgentName?` through undo, redo, and `amend`. The Undo and Redo items name the agent of the entry. The server and its UI name no single client: the setup commands cover Claude Code, Codex, opencode, and any MCP app, and an app path in App Translocation or on a disk image gives no command.

## Consequences

- A call on a package that the app has open is one undo step in the app. The edit tool descriptions say this, and say that a call on files has no undo.
- One `claude mcp add` registration serves the files and the app.
- Any process of the same user can connect to the socket: the same trust as `dirigible` in a terminal.
- A main actor that is busy for more than 30 s gives an error with an unknown result. The text tells the agent to read the session before it tries again.
- On a network home folder, `flock` can fail; the server then does not start, and Settings says so.
- `Studio.edit` gets an `agent` parameter; `History` entries get a label.

## Alternatives considered

- **Streamable HTTP in the app** (the Figma shape). Rejected: an HTTP parser, `Origin` checks, a token, a free port, and a possible firewall prompt for an ad-hoc signed app.
- **A byte relay, with the whole MCP server in the app.** Rejected: the era state moves into the app, a second registration is necessary, and every call fails when the app quits.
- **XPC or Apple Events.** Rejected: Claude Code cannot call them, so a bridge is still necessary, plus a launchd install step or a permission prompt.
- **A server for each window.** Rejected: with no window open, an agent gets no answer, and two windows need two sockets.
- **A `Task` for each connection with blocking reads.** Rejected: a blocking `accept` or `read` holds a thread of the cooperative pool.
- **A connect probe for a stale socket.** Rejected: two copies that start at the same time can both unlink and bind. The `flock` has no such race.

## Sources

- Claude Code MCP documentation (transports). https://code.claude.com/docs/en/mcp
- MCP specification 2026-07-28, transports (a custom transport reuses the stdio framing). https://modelcontextprotocol.io/specification/2026-07-28/basic/transports
- Figma desktop MCP server. https://developers.figma.com/docs/figma-mcp-server/local-server-installation
