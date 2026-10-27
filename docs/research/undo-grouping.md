# Undo grouping and batch tool calls

Rejected design: this research recommended History grouping (`NSUndoManager` groups). Decision 0063 rejects it and uses one nested edit body (`docs/decisions/0063-agent-batch.md`).

Date: 2026-10-26

Scope: the facts behind decision 0063, the MCP tool `batch` that applies a list of edit calls as one undo step. Numbers in brackets are entries in `## Sources`. Fetches and clones were done on 2026-10-26. No probe ran, so each claim about the run-time behavior of `NSUndoManager` comes from documentation or source code.

## NSUndoManager grouping (the rejected alternative)

- `beginUndoGrouping()` and `endUndoGrouping()` group all operations back to the matching begin, and groups can nest [2][3].
- Apple documents no abort or rollback call for a group. `endUndoGrouping()` only closes it [3].
- `undoNestedGroup()` undoes the last group and records it on the redo stack [7][15]. Only a new undo operation clears the redo stack [13]. Inference: a rollback by `undoNestedGroup()` leaves a redo entry until the next edit.
- With `groupsByEvent = true` (the default), the manager opens a group for each pass of the run loop [4][13]. A batch group in the same pass as another edit is nested in the event group. The documentation does not say what one Undo then reverses.

## Atomic batches in real MCP servers

All four were read at the commit shown in `## Sources`.

- The filesystem server `edit_file` applies its edits in memory in order and writes only after the loop, so a failed edit writes nothing [38].
- mcp-unity `batch_execute` takes 1 to 100 items of `{tool, params, id?}`. With `atomic`, it reverts down to its undo group on the first failure. Each result has an `index`. It rejects a nested `batch_execute` [39].
- Unity MCP `batch_execute` has no rollback. Its default limit is 25, and its hard maximum is 100 [40].
- REAPER MCP `batch_update_tracks` takes 1 to 64 items. It checks every item first, then runs one undo block labeled `Batch update N tracks` [41].
- Pattern: the atomic servers check all items first or revert on the first failure. Only mcp-unity puts an index in the result. Real limits are 100, 64, and 25 items [39][40][41].
- Apple HIG: "Consider giving people the option to revert multiple changes at once" for "a batch of discrete but related actions" [18].

## MCP protocol

- JSON-RPC batching is not a tool batch. The 2025-03-26 spec added it, and the 2025-06-18 spec removed it [28][29][33]. JSON-RPC 2.0 lets a server process a batch in any order [34], so a protocol batch cannot give one undo step.
- A tool that fails returns a result with `isError: true` and a text item. An input validation error is a tool execution error, not a protocol error [30][35][36].
- `structuredContent` and `outputSchema` came with spec 2025-06-18 [29][35]. A tool with an `outputSchema` must give conforming structured results, and the TypeScript SDK skips that check when `isError` is true [35][42].

## Sources

- [2] https://developer.apple.com/documentation/foundation/undomanager/beginundogrouping() - begin, nesting, event-loop default.
- [3] https://developer.apple.com/documentation/foundation/undomanager/endundogrouping() - group semantics, "nested transactions", exception.
- [4] https://developer.apple.com/documentation/foundation/undomanager/groupsbyevent - default true, close groups yourself when false.
- [7] https://developer.apple.com/documentation/foundation/undomanager/undonestedgroup() - undo of the last group, one redo group.
- [13] https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/UndoArchitecture/Articles/UndoManager.html - groups, run-loop grouping, redo stack cleared by a new operation.
- [15] https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/UndoArchitecture/Articles/PerformingUndo.html - `undo` versus `undoNestedGroup`.
- [18] https://developer.apple.com/design/human-interface-guidelines/undo-and-redo - menu label naming, revert a batch.
- [28] https://modelcontextprotocol.io/specification/2025-03-26/changelog - batching added (PR #228).
- [29] https://modelcontextprotocol.io/specification/2025-06-18/changelog - batching removed (PR #416), structured tool output added (PR #371).
- [30] https://modelcontextprotocol.io/specification/2025-11-25/changelog - SEP-1303 input validation errors.
- [33] https://github.com/modelcontextprotocol/modelcontextprotocol/pull/416 - reason for the removal.
- [34] https://www.jsonrpc.org/specification - section 6 Batch.
- [35] https://modelcontextprotocol.io/specification/2025-06-18/server/tools.md - Structured Content, Output Schema, Error Handling.
- [36] https://modelcontextprotocol.io/specification/2026-07-28/server/tools.md - same sections, newest version.
- [38] https://github.com/modelcontextprotocol/servers/tree/ef9808f71090d0db3eda99e2af2ba78f1086f4fb/src/filesystem - `server.ts`, `lib.ts` (`edit_file`, `read_multiple_files`).
- [39] https://github.com/CoderGamester/mcp-unity/tree/d572dc88f1b982a0fdfc09cd14cfdfd760b658e8 - `Editor/Tools/BatchExecuteTool.cs`, `Server~/src/tools/batchExecuteTool.ts`.
- [40] https://github.com/CoplayDev/unity-mcp/tree/ed4e205d31a545bac3686d5e19210e67959aeddd - `Server/src/services/tools/batch_execute.py`, `MCPForUnity/Editor/Tools/BatchExecute.cs`, `website/docs/reference/tools/core/batch_execute.md`.
- [41] https://github.com/danishaft/reaper-mcp/tree/b4c0487010ff5d5033ce37484da6a56b9c6a8f27 - `src/reaper_mcp/services/batch_service.py`, `src/reaper_mcp/tools/batch.py`, `lua/reaper_mcp_bridge_modules/command_execution.lua`; README "Every write is validated before execution and appears as one named REAPER undo step."
- [42] https://github.com/modelcontextprotocol/typescript-sdk/blob/b415e60bdf0e8dd5d6cbe7e6353abfb982b06dd2/packages/server/src/server/mcp.ts - `createToolError` (line 333), `validateToolOutput` (line 385).
