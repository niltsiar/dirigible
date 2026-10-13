# 0048. Record with consent: one `record` call that waits 20 s for the answer of the user

- Status: accepted
- Date accepted: 2026-10-13, after the plan gate of run `2026-10-12-record-with-consent`.
- Date: 2026-10-12
- Amends: 0041 (the `record` tool exists; no tool records on files; a live `record` with no `playhead` starts at the window playhead, not 0), 0046 (an `AgentTarget` can ask its window to record; a connection reads during its call, and a close or a stop cancels the call).

## Context

R16: "An agent can start a recording only after the user clicks Record in a consent sheet of the app." 0041 has no `record` tool for this reason. 0046 gives the app server: the bridge `dirigible mcp` waits 30 s or less for a reply, and the live executor runs each call on the main actor. MCP clients have their own call limits: Codex has `tool_timeout_sec`, default 60 s (`docs/research/mcp-clients.md`). A human answer has no limit. Design: `.scratchpads/runs/2026-10-12-record-with-consent/design.md`.

## Decision

- **Tool.** `record` takes the options of `dirigible record`: `package`, `seconds` (more than 0, 86400 or less), `arm` (one or more track IDs), and `playhead`. The CLI and the tool call one rule owner (`EditRules.takeSeconds`). `RecordRequest.answerLimit` in `DirigibleMCP` holds the 20 s, so the tool description and the sheet use one value. With no `playhead`, the take starts at the playhead of the window (0016), and the sheet shows it.
- **Files.** On files (the app server is off, or no window has the package), `record` gives `isError: true`: "To record, open `<path>` in Dirigible and turn on Let Agents Edit Open Sessions in Settings. A take needs the consent of the user in the app." It reads no package and takes no lock.
- **Resolve at the ask.** Before the sheet shows, the window resolves the request tracks (ID, name, route) and one start frame (`playhead`, else the window playhead at the ask), and stores them. The take records these values, so it records what the sheet showed. An unknown, unrouted, or duplicate track is refused at once.
- **Sheet.** On an open package, the window shows a sheet with the agent name (`AgentName`), the track names, the length, the start time, and a record-over line when a request track has a clip after the start. It has two buttons: Don't Record (Escape) on the left and Record on the right. No button is the default, and Record has no key equivalent, so a Return typed in another field never starts a take. The sheet has its own state on the window, not the `alert` slot.
- **One reply.** The call replies once, after one of these ends: Record and a successful start ("Take <n> records on <tracks> for <s> s ..."), a start error (the CLI text), Don't Record ("The user did not record."), the expiry, or a window close or Quit ("closed"). Each reply except the start is `isError: true`.
- **Phases.** A request is `waiting` (the sheet shows) or `starting` (after the Record click). The click moves to `starting` and stops the expiry in one synchronous step. The expiry, Don't Record, and Record act only in `waiting`, so a long microphone prompt cannot give a second reply or a second take.
- **Expiry.** A request lives 20 s. Then the sheet closes, an info banner says that the request ended with no answer, and the reply says that the user did not answer. A `userInitiated` activity token lives with the request, so App Nap does not make the expiry late. 20 s plus the take start fits in the 30 s reply limit of the bridge. A sheet never waits for a request that the agent no longer waits for: a close of the bridge or a stop of the server cancels the call, and a waiting request then ends as with no answer. A cancel after the Record click does not stop the start: the user gave consent.
- **Refusal at once.** A request is refused with no sheet when the window shows an alert, a sheet, or a panel, has a drag, a take, or a pending take, is not open, or is minimized, and when another request waits.
- **Attention.** The sheet does not bring its window to the front and does not activate the app (0046 C17). When the app is not active, the Dock icon asks for attention (`.criticalRequest`) until the app is active or the request ends.
- **The take.** Record runs the same window path as Command-R (drafts, microphone access, the alerts), with the tracks and the playhead of the request. The window armed set does not change. A window timer stops the take after `seconds`; a Stop of the user ends it earlier. The shared record body returns `started(take:)`, `notStarted`, or `failed`; the reply comes when the start returns, with the take number read from the transport at once. The agent reads `session_info`: `recording` goes when the take ends.
- **Owners.** `SessionWindow` owns the pending request (`consent`) and the stop timer (`agentStop`). `ConsentRequest` owns the phase, the reply continuation, the expiry task, and the activity token; its `finish` is one-shot. `AgentServer` sends `record` to `liveRecord`, the one async live call; while a request waits, the target of the window is busy (`AgentBusy.asking`). `startTake(armed:playhead:)` is the one take start of Command-R and the sheet, and returns `RecordStart`. `Studio` keeps the take, with no change.

## Consequences

- An agent edit while a request waits is refused as busy, so the tracks of the sheet cannot change.
- A user who does not answer in 20 s gets no take. The agent asks again.
- The first app-audio or microphone prompt can hold the start past the bridge limit. The agent then gets the 0046 lost-reply error and reads the session.
- The take length has the error of one main-actor hop, not the exact end of `dirigible record`.

## Alternatives considered

- **Ask, then read.** The call returns at once, and the agent polls a new `session_info` key. Rejected: a new contract key with five states, a poll loop, and a click hours later still records.
- **A reply at the take end** (the CLI shape). Rejected: a take of up to 24 h; no client waits that long.
- **MCP elicitation.** Rejected: the agent asks in its own UI, and an agent can approve its own question. R16 asks for a sheet of the app.
- **A `started` hook in `Studio.record`, or a public take length.** Rejected for now: a change in a risk path for a few milliseconds of length.

## Sources

- MCP specification 2026-07-28, tools and elicitation. https://modelcontextprotocol.io/specification/2026-07-28/
- Codex MCP configuration (`tool_timeout_sec`). https://developers.openai.com/codex/mcp
