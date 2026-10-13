# 0049. Progress and cancel of an MCP tool call

- Status: accepted
- Date: 2026-10-13
- Accepted: 2026-10-13, after plan gates 1 and 2 of run `2026-10-13-mcp-long-tools`.
- Amends: 0041 (the five long commands get tools; a request can read stdin while it runs; no answer after a seen cancel), 0046 (progress frames; the reply limit is 30 s with no frame; a long call on an open package runs in the app), 0048 (the bridge watches stdin during each call; EOF still ends only a `record` call; a cancelled call gets no answer), 0040 (a cancel after the rename removes the renamed WAV; a failed `session.xml` write and Undo still keep it).

## Context

R16: the agent tools cover the `dirigible` commands. `export`, `render`, `level`, `loudness`, and `import` run for seconds to minutes, so 0041 left them out until a tool call has progress and cancel. MCP has `notifications/progress` for a request with `_meta.progressToken`, and `notifications/cancelled` with `requestId`. Claude Code, Codex, and opencode send a progress token on each call. Claude Code and opencode reset their call timeout on progress, and opencode stops a call with no progress for 60 s. Codex has a hard call limit and sends no cancel. Claude Code and opencode cancel with `requestId` ([the progress research](../research/mcp-progress.md)). Hindenburg PRO has no agent interface. Design: `.scratchpads/runs/2026-10-13-mcp-long-tools/design.md`.

## Decision

- **Call control.** `MCPServer` makes one `CallControl` for each `tools/call` and gives it to the route and to the tool. The control has the progress token, `report(fraction)`, and `isCancelled()`. `MCPServer` knows no tool. A cancel matches the `requestId` of the running call, never the token. A cancel for another ID, or for a call that ended, changes nothing. Before a `tools/call` runs, the server scans the buffer for its cancel: a call that the client cancelled while it waited does not run and gets no answer.
- **Threads.** `dirigible mcp` adds no thread. A request runs on the stdin thread, one at a time (0041). The job calls `isCancelled()` at each chunk, block, or clip; the call reads stdin after a poll of 0 ms, at most once in 100 ms, and the first call always reads. A request that comes during a job waits in the buffer. EOF of stdin does not cancel a call, except a `record` call (0048). After EOF, no poll reads stdin again.
- **Progress.** `progress` is the fraction x 100 with one decimal, and `total` is 100. One gate at each send point passes a value that grows by 1 or more, or that grows at all 10 s after the last pass. So the client gets a value that always grows, at most about one line for each percent, and a line in each 10 s of work. A call with no token gets no progress line.
- **Cancel.** A seen cancel makes the job throw `cancelled` before its commit point (the move of an export, the save of an edit); the job then writes nothing, and the call gets no answer. A cancelled import removes the WAV that it renamed into `Clips/`, whichever read sees the cancel; a flush fault, a failed `session.xml` write, and Undo keep it (0040). The fraction of a call that measures clips is the frames done over the total frames of the clips. A cancel after the commit point is late: the result stays, and the answer goes out when the connection is still open. The tool descriptions tell the agent to read the session after a cancel.
- **Bridge.** The bridge watches stdin during each forwarded call, and keeps one read buffer for the whole call. A cancel closes the socket fully (not a half-close), so the listener ends the connection and cancels the call task. The app sends zero or more `{"progress": <0...1>}` lines before the reply line, gated as above. A hop of a `Studio` job passes the main actor, then the listener queue, so a main actor that stalls still gives the lost-call text. The listener writes a frame only while its call has no reply, so a late frame never reaches the next call. Each progress line restarts the 30 s reply limit. With no line for 30 s, the 0046 lost-call rule applies.
- **Where a job runs.** With the app server on and the package open, the five tools run in the app: `export` and `render` through `Studio.export` (a take start ends them, 0019; the window shows the export sheet, and its Cancel ends the call), `level` and `import` through `Studio` as one undo step that names the agent, and `loudness` through `Studio.loudness` (the window session, the package through the lock, a stop at a cancel of the caller), because an edit does not wait for its autosave. The window banner of an agent level or import shows the progress of the studio, and its Cancel stops the job. Else they run in `dirigible mcp`: `level` and `import` under the package lock, and `export`, `render`, and `loudness` with no lock, as the CLI.

## Consequences

- `ParityTests.toolExemptions` loses `import`, `level`, `loudness`, `render`, and `export`. `capture place`, `take finalize`, and `peaks` keep their exemption.
- Each long tool has one owner for its argument rules and its text, shared with its command (0041). The warnings that the CLI writes to stderr are lines of the tool result.
- A `ping` or another request waits for the end of a running job.
- Codex stops a call at its own limit (`tool_timeout_sec`) and sends no cancel: the job runs to its end. The guide tells a Codex user to raise `tool_timeout_sec`.
- A stalled read (for example an online-only file) gives no progress: the bridge gives the lost-call text after 30 s, and opencode stops the call after 60 s and cancels it.
- An agent export shows the modal export sheet in the window of the package.
- `export`, `render`, and `chapters export` refuse an output path inside a session package, for the commands and the tools, so no export can replace recorded audio.

## Alternatives considered

- **A stdin reader thread with a cancel token for each request.** Rejected: a second stdin owner, a stdout lock, and a new EOF rule, while a scan of the buffer already drops a queued request that the client cancelled.
- **A job thread that keeps the stdin loop free.** Rejected: requests in flight and a second stdout writer, only to answer `ping` during a job.
- **A job handle and a status tool, or the MCP tasks extension.** Rejected: not tool-agnostic, tools with no command, and no client support was found.
- **`cancel` and `alive` frames on the socket.** Rejected: a full close already cancels the call, and each job reports at each block.
- **`export`, `render`, and `loudness` always on the files.** Rejected: an agent export could run during a take, and `loudness` could read a session that the window did not save yet.

## Sources

- MCP specification 2026-07-28, progress. https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/progress
- MCP specification 2026-07-28, cancellation. https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/cancellation
- `docs/research/mcp-progress.md` (client behavior: Claude Code 2.1.296, Codex rust-v0.162.1, opencode 1.19.0).
