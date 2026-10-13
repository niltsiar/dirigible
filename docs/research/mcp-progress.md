# Progress, timeouts, and cancellation of long MCP tool calls in three clients

Date: 2026-10-13

Question: what do Claude Code, Codex CLI, and opencode do with `_meta.progressToken`, `notifications/progress`, timeouts, and `notifications/cancelled` on a long `tools/call` to a stdio server? What does the MCP specification 2026-07-28 require?

Versions: Claude Code 2.1.296 (installed, latest release [S12]). Codex tag `rust-v0.162.1` (latest release; Codex is not installed). opencode 1.18.30 installed, tag `v1.19.0` read; the tool-call code is the same in both tags [S8].

Evidence labels: "source" is code on GitHub at the given tag. "docs" is an official docs page. "P3" is a read-only probe: `strings` of the installed Claude Code binary, which bundles the MCP TypeScript SDK and the tool-call code. P3 ran no client. Claude Code has no public source, so P3 is the only code evidence for it.

## 1. MCP specification 2026-07-28

The pages moved from `basic/utilities/` to `basic/patterns/` [S1, S2].

### Progress [S1]

- The client puts `progressToken` in `params._meta`. The token "MUST be a string or integer value". It "MUST be unique across all active requests".
- Only the server sends progress in 2026-07-28. The server "MAY" send `notifications/progress` with `progressToken`, `progress`, an optional `total`, and an optional `message`.
- "The `progress` value MUST increase with each notification, even if the total is unknown." `progress` and `total` "MAY be floating point".
- A notification "MUST only reference tokens that" belong to an active request and an operation in progress.
- The server "MAY" send no progress, and "MAY" send at any frequency. "Both parties SHOULD implement rate limiting to prevent flooding."
- "Progress notifications MUST stop after completion."

### Cancellation [S2]

- Shape: `{"method":"notifications/cancelled","params":{"requestId":"123","reason":"User requested cancellation"}}`. `reason` is optional.
- stdio: "The client MUST send a `notifications/cancelled` notification referencing the request ID." Streamable HTTP: a closed response stream is the cancel signal.
- A server that receives a cancel "SHOULD" stop the work, free the resources, and "Not send a response for the cancelled request".
- A server "MAY ignore" a cancel when the request is unknown, already complete, or cannot be cancelled. "Invalid cancellation notifications SHOULD be ignored": unknown IDs, completed requests, malformed notifications.
- "The client SHOULD ignore any response to the cancelled request that arrives afterward." Thus a response after a cancel is not a protocol error, but the server should not send it.
- Both sides "MUST handle these race conditions gracefully": a cancel can arrive after the response.
- "Servers MUST NOT send `notifications/cancelled`" for any purpose other than the end of a `subscriptions/listen` stream.
- Timeouts: a sender "SHOULD" set a timeout and cancel on expiry. It "MAY" reset the timeout on a progress notification, but "SHOULD always enforce a maximum timeout, regardless of progress notifications".

### Changes from 2025-11-25

- 2025-11-25 had the timeout rules in the lifecycle page [S3]. 2026-07-28 moves them to the cancellation page [S2].
- 2025-11-25 let either side send progress and cancels, and said a party "should" cancel. 2026-07-28 makes the server the only sender of progress, and a stdio client MUST send `notifications/cancelled` [S1, S2, S4, S5].
- New: the server MUST NOT send `notifications/cancelled`, except for `subscriptions/listen` [S2].
- Removed: "The `initialize` request MUST NOT be cancelled". 2026-07-28 has no `initialize` handshake [S5, S6].
- Tasks: 2025-11-25 had tasks in the core, with `tasks/cancel` in place of `notifications/cancelled` for a task, and progress tokens that live for the task lifetime [S4, S5]. 2026-07-28 moves tasks to the extension `io.modelcontextprotocol/tasks`, with polling through `tasks/get` [S6]. The progress page of 2026-07-28 has no task rule [S1].
- The cancel shape and the progress shape are the same in both revisions [S1, S2, S4, S5].

## 2. Claude Code

1. **progressToken.** Always sent. Both tool-call paths (v1 and v2 runtime) pass an `onprogress` callback to the SDK `callTool`. The bundled SDK sets `_meta.progressToken` to the JSON-RPC request ID (an integer) when `onprogress` is present (P3). The `_meta` also carries other keys, for example `claudecode/toolUseId` (P3). The docs say that the idle timer resets on progress [S7], which needs a token. Not confirmed in source on GitHub: only P3.
2. **Default timeout.** Two timers [S7, S12]:
   - Wall-clock: `MCP_TOOL_TIMEOUT` in ms, default 100000000 (about 28 hours). A per-server `"timeout"` in ms (1000 or more) in the server entry overrides it for that server.
   - Idle: no response and no progress for 30 minutes on stdio (5 minutes on HTTP, SSE, and WebSocket) aborts the call. Change it with `CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT` in ms; `0` disables it. A per-server `timeout` of 1000 or more is a floor for the idle window. Stdio has the idle timeout since v2.1.203.
   - `MCP_TIMEOUT` is the startup timeout (default 30000 ms), not a tool timeout [S12].
   - P3 agrees: idle defaults `300000` and `1800000`, a watchdog that checks every 30 s.
3. **Progress resets the timeout.** Progress resets the idle timer only. "The per-server `timeout` is a hard wall-clock limit per tool call, and progress notifications from the server don't extend it" [S7]. P3 agrees: the SDK call has `timeout` set to the wall-clock value and no `resetTimeoutOnProgress`; `onprogress` sets the idle start time to now. Max total: the wall-clock limit, 28 hours by default.
4. **Progress display.** The user sees it. While the call runs, the spinner text shows `<message> (NN%)` when `total` is above 0, or the message, or `Processing… <progress>` (P3). A main-conversation call that runs for more than 2 minutes moves to a background task, and its `/tasks` entry "shows the latest progress the server has reported" [S7]. Inference: the model does not see progress, because P3 shows progress only in UI events, not in the tool result.
5. **Cancel.**
   - User interrupt (Esc): the call gets an `AbortSignal`. The bundled SDK sends `notifications/cancelled` with `requestId` and `reason: String(signal.reason)` when the signal aborts (P3). The text of the reason is not confirmed.
   - Own wall-clock timeout: the SDK timer has the same value, and on expiry it sends `notifications/cancelled` with the reason `String(McpError("Request timed out"))` (P3).
   - Own idle timeout: the watchdog rejects the call, but P3 shows no abort of the SDK request in that path. Not confirmed if a `notifications/cancelled` follows.
   - The user can also stop a backgrounded call in `/tasks` [S7]. Not confirmed which message the server gets.
   - P3 shows no kill of the server process on a tool timeout. Not confirmed.

## 3. OpenAI Codex CLI

1. **progressToken.** Always sent. rmcp 3.3.0 (the version that Codex pins [S9]) sets `_meta.progressToken` on every request from a counter [S10]. The token comes from a different counter than the request ID, so the token and the `requestId` can differ [S10].
2. **Default timeout.** `tool_timeout_sec` in `[mcp_servers.<name>]` of `~/.codex/config.toml`, in seconds. The docs say "Default: `60`" [S11]. The source at `rust-v0.162.1` has `DEFAULT_TOOL_TIMEOUT = 300` seconds, and `main` has the same [S9]. The two do not agree. Design for 60 s.
3. **Progress resets the timeout.** No. Codex sends the request with `PeerRequestOptions::no_options()`, so the rmcp timeout and the rmcp progress reset do not run [S9]. Codex wraps the call in its own `active_time_timeout`, which pauses only while an elicitation is open [S9]. The timeout is a hard limit.
4. **Progress display.** No. The client handler only writes progress to the `info!` log [S9].
5. **Cancel.** No `notifications/cancelled` is sent, on the timeout or on an interrupt.
   - On timeout, `active_time_timeout` drops the request future [S9]. rmcp sends a cancel only from `RequestHandle::cancel` or from its own timeout, and the handle has no drop hook [S10].
   - On a user interrupt, the turn calls `dispatch_handle.abort()` on the tool task and returns an "aborted" result to the model [S9].
   - No code was found that closes or restarts the connection after a tool timeout. Not probed: Codex is not installed.
   - Consequence: the job continues on the server. Inference: rmcp discards the late response.

## 4. opencode

1. **progressToken.** Always sent. `callTool` gets `onprogress: () => {}`, with the comment "The MCP SDK only sends a progress token when this hook is present, enabling timeout resets" [S8]. SDK 1.29.0 then sets `progressToken` to the request ID (an integer) [S8, S13].
2. **Default timeout.** 60000 ms. opencode passes `timeout` from the per-server `timeout` (ms), else `experimental.mcp_timeout` (ms), else `undefined` [S8]. With `undefined`, SDK 1.29.0 uses `DEFAULT_REQUEST_TIMEOUT_MSEC = 60000` [S13].
   - Mismatch: the schema text of the per-server `timeout` says "Defaults to 5000" [S8], and the docs say it is the time to fetch tools [S14]. In the code, the connect default is 30000 ms, and the same key also sets the tool-call timeout [S8].
   - Trap: a user who sets `"timeout": 5000` for a slow start also gets a 5 s idle timeout on each tool call.
3. **Progress resets the timeout.** Yes. opencode passes `resetTimeoutOnProgress: true` and no `maxTotalTimeout` [S8]. In SDK 1.29.0 each progress notification restarts the timer, and with no `maxTotalTimeout` "there is no maximum total timeout" [S13]. A call can run for any time if progress arrives within each 60 s window.
4. **Progress display.** No. The `onprogress` callback does nothing [S8].
5. **Cancel.** opencode passes the AI SDK `abortSignal` as `signal` [S8]. When the signal aborts, or when the SDK timer expires, SDK 1.29.0 sends `notifications/cancelled` with `requestId` and `reason: String(reason)` [S13].
   - On timeout, the reason is the text of `McpError` "Request timed out" [S13].
   - On a user interrupt: the LLM stream owns an `AbortController`, and the release of the stream scope calls `ctrl.abort()` with no reason [S8]. Inference: Esc ends that scope, so the server gets `notifications/cancelled` with a reason such as `AbortError: This operation was aborted`.
   - No kill of the server process was found. Not confirmed.

## Consequences for the Dirigible server

- Read `_meta.progressToken` as a string or an integer. All three clients send an integer today. Echo the value with its JSON type. Never assume that the token is equal to the request ID (Codex).
- Accept unknown `_meta` keys (Claude Code sends extra keys).
- Send progress at a fixed interval while a job runs, also when the fraction does not change: opencode stops the call after 60 s with no progress. Inference: an interval of 10 s to 20 s keeps opencode alive and stays far below a flood. The spec asks for a rate limit [S1].
- Keep `progress` strictly increasing. A heartbeat with no new work must still increase `progress`, for example by a small step, or by a value in work units that grows with time. Inference: this is the only legal heartbeat.
- Send no progress after the response, and no response after a cancel [S1, S2].
- Ignore a cancel for an unknown or finished request [S2].
- Do not depend on `notifications/cancelled` to stop orphaned jobs. Codex never sends it, and the Claude Code idle-timeout path is not confirmed. The server needs its own job limit.
- Codex is the hard limit: 60 s (docs) or 300 s (source), with no reset on progress. Inference: a job that can run longer needs a plan decision, for example a tool that returns a job handle and a status tool, or the tasks extension. Not checked: Codex support for the tasks extension.
- Default longest call: Claude Code about 28 hours wall-clock with a 30-minute idle window (moved to the background after 2 minutes); opencode no limit while progress arrives within 60 s; Codex 60 s or 300 s.

## Open questions

- P4 (not run; the caller limited probes to version checks): a stdio logger server that logs each line of stdin to a file, answers `tools/list` with one tool, and answers `tools/call` after 120 s with progress every 10 s. Run it with `claude -p` and with `opencode run`, then press Esc in an interactive session. It confirms the token type, the `_meta` keys, and the `reason` text of each cancel. Put it in a new folder under `.scratchpads/` and run it with `scripts/probe.sh`.
- Does Claude Code send `notifications/cancelled` after its idle timeout? P4 with `CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT=60000` and no progress answers it.
- Which Codex default is true for users, 60 s or 300 s? Install Codex and run P4 with no progress.

## Summary table

| Client | progressToken sent | Default timeout | Progress resets timeout | Cancel shape |
|---|---|---|---|---|
| Claude Code 2.1.296 | Always; integer equal to the request ID (P3) | Wall-clock about 28 h (`MCP_TOOL_TIMEOUT` or per-server `timeout`); idle 30 min on stdio (`CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT`) | Idle timer yes; wall-clock no | `notifications/cancelled` with `requestId` and `reason` on Esc and on the wall-clock timeout (P3); idle timeout not confirmed |
| Codex `rust-v0.162.1` | Always; integer from its own counter, not the request ID | `tool_timeout_sec`: 60 s in docs, 300 s in source | No; hard limit | None; Codex drops the request future on timeout and on interrupt |
| opencode 1.18.30 / 1.19.0 | Always; integer equal to the request ID | 60 s (SDK default); per-server `timeout` or `experimental.mcp_timeout` in ms | Yes; no max total | `notifications/cancelled` with `requestId` and `reason` on abort and on timeout |

## Sources

- S1: MCP specification 2026-07-28, Progress, https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/progress (file `docs/specification/2026-07-28/basic/patterns/progress.mdx` in https://github.com/modelcontextprotocol/modelcontextprotocol, branch `main`, read 2026-10-13)
- S2: MCP specification 2026-07-28, Cancellation, https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/cancellation (file `docs/specification/2026-07-28/basic/patterns/cancellation.mdx`, branch `main`, read 2026-10-13)
- S3: MCP specification 2025-11-25, Lifecycle, Timeouts, https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle (read 2026-10-13)
- S4: MCP specification 2025-11-25, Progress, https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/progress (read 2026-10-13)
- S5: MCP specification 2025-11-25, Cancellation, https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/cancellation (read 2026-10-13)
- S6: MCP specification 2026-07-28, Key Changes, https://modelcontextprotocol.io/specification/2026-07-28/changelog (read 2026-10-13)
- S7: Claude Code docs, "Connect Claude Code to tools via MCP", timeouts and "Automatic backgrounding of long tool calls", https://code.claude.com/docs/en/mcp (read 2026-10-13)
- S8: anomalyco/opencode, tag `v1.19.0` (2026-10-11): `packages/opencode/src/mcp/catalog.ts` lines 54-66, `packages/opencode/src/mcp/index.ts` lines 38 and 661-684, `packages/opencode/src/session/llm.ts` lines 321 and 357-365, `packages/core/src/v1/config/mcp.ts` lines 20-21, `packages/core/src/v1/config/config.ts` lines 182-183, `packages/opencode/package.json` (SDK `1.29.0`); `catalog.ts` and `package.json` are the same at tag `v1.18.30`. https://github.com/anomalyco/opencode/blob/v1.19.0/packages/opencode/src/mcp/catalog.ts
- S9: openai/codex, tag `rust-v0.162.1` (2026-10-09): `codex-rs/codex-mcp/src/rmcp_client.rs` line 107 (`DEFAULT_TOOL_TIMEOUT`), `codex-rs/codex-mcp/src/connection_manager.rs` lines 362-366 and 1021-1034, `codex-rs/rmcp-client/src/rmcp_client.rs` lines 239-275, 819-900, 1482-1505, `codex-rs/rmcp-client/src/tool_input.rs` lines 39-56, `codex-rs/rmcp-client/src/logging_client_handler.rs` lines 52-72, `codex-rs/core/src/tools/parallel.rs` lines 249-282, `codex-rs/Cargo.toml` line 452 (rmcp pin). https://github.com/openai/codex/blob/rust-v0.162.1/codex-rs/rmcp-client/src/rmcp_client.rs
- S10: modelcontextprotocol/rust-sdk (rmcp 3.3.0), rev `3e636cab26c013eca5131103c03d20237f12c4df`, `crates/rmcp/src/service.rs` lines 529-680 (`RequestHandle`, `await_response`, `cancel`) and 809-893 (separate request-ID and progress-token counters, `set_progress_token`). https://github.com/modelcontextprotocol/rust-sdk/blob/3e636cab26c013eca5131103c03d20237f12c4df/crates/rmcp/src/service.rs
- S11: OpenAI Codex docs, MCP, https://learn.chatgpt.com/docs/extend/mcp?surface=cli (read 2026-10-13)
- S12: Claude Code docs, environment variables, `MCP_TIMEOUT`, `MCP_TOOL_TIMEOUT`, `CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT`, https://code.claude.com/docs/en/env-vars (read 2026-10-13); release `v2.1.296` (2026-10-09), https://github.com/anthropics/claude-code/releases/tag/v2.1.296
- S13: modelcontextprotocol/typescript-sdk, tag `v1.29.0`, `src/shared/protocol.ts` lines 106 (`DEFAULT_REQUEST_TIMEOUT_MSEC = 60000`), 124-143 (`timeout`, `resetTimeoutOnProgress`, `maxTotalTimeout`), 576-592 (`_resetTimeout`), 856-883 (`_onprogress`), 1136-1218 (progress token and `notifications/cancelled`). https://github.com/modelcontextprotocol/typescript-sdk/blob/v1.29.0/src/shared/protocol.ts
- S14: opencode docs, MCP servers, https://opencode.ai/docs/mcp-servers/ (read 2026-10-12, cited in `docs/research/mcp-clients.md`)
- P3: probe, `strings -n 8` of `/usr/local/Caskroom/claude-code@latest/2.1.296/claude` (installed Claude Code 2.1.296), read-only, run 2026-10-13. Searched for `resetTimeoutOnProgress`, `onprogress`, `mcp_progress`, `getMcpToolIdleTimeoutMs`. No client ran.
