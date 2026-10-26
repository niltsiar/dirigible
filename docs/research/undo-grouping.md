# Undo grouping and batch tool calls

Date: 2026-10-26

Scope: reference behavior for an MCP tool `batch` that applies a list of edit calls as one undo step. Numbers in brackets are entries in `## Sources`. Fetches and clones were done on 2026-10-26. No `swift` command and no build ran (the brief forbids them), so every claim about run-time behavior of `NSUndoManager` is from documentation or from source code, not from a probe.

## Summary

- Wrap the whole batch in one `beginUndoGrouping()` / `endUndoGrouping()` pair. Apple says all undo operations back to the matching begin "are grouped together and reversed by a later undo()" [3].
- Name the step once, with `setActionName(_:)`, after the last edit and before `endUndoGrouping()`. Apple documents one name per Undo command and does not say what a second call does [8][14]. GNUstep replaces the name of the open group, so the last call wins there [17]. Confirm on macOS with the probe in `## Open questions`.
- Default name: one noun phrase with a count, for example "Batch (N edits)". The sources that name a grouped step do the same: REAPER MCP uses "Batch update N tracks" [41]. mcp-unity uses "Batch Execute" [39]. Final Cut Pro uses one name, "Undo Text Replace", for its Replace All command [23]. This default is an inference.
- Logic Pro, GarageBand, and Hindenburg manuals say nothing about the name of a grouped step. Do not cite them as a precedent either way [19][22][25].
- Failure inside a group: Apple documents no rollback. Every source that gives all-or-nothing checks the whole list first, or edits in memory and writes at the end [38][41]. Default: check all items, apply none on failure. If an apply fails after a partial change, call `endUndoGrouping()` and then `undoNestedGroup()` [7].
- Result shape: one result per item with `index`, `success`, and `result` or `error`, plus a summary with `total`, `succeeded`, `failed` [39]. Keep the order of the input list.
- MCP failure: a tool that fails returns a result with `isError: true` and a text item. A malformed call or an unknown tool is a JSON-RPC error [35][36]. A rolled-back batch is the first case.
- JSON-RPC batching is not a tool batch. The 2025-03-26 spec added it and the 2025-06-18 spec removed it [28][29]. Cap the list at 100 items or fewer: real servers use 100, 64, and 25 [39][40][41].

## 1. NSUndoManager grouping

Apple names the class `UndoManager` in Swift and `NSUndoManager` in Objective-C [1].

### Begin and end

- `beginUndoGrouping()` marks the start of a group. Apple: "By default undo groups are begun automatically at the start of the event loop, but you can begin your own undo groups with this method, and nest them within other groups." [2]
- `endUndoGrouping()` groups all operations back to the matching begin. Apple: "Undo groups can be nested, thus providing functionality similar to nested transactions." It raises `NSInternalInconsistencyException` if no begin is in effect [3].
- `groupingLevel` counts the open nested groups. A value of 0 means no open group [5].

### groupsByEvent

- The default is `true`. The manager makes a group around each pass of the run loop [4].
- The archived guide says the same: the first undo operation in a run-loop pass opens a group, and the group closes at the end of the pass. It adds "To undo a single operation, it must still be packaged in a group." [13]
- With `groupsByEvent = false`, you must close groups yourself before `undo()` or `undoNestedGroup()` [4][15].
- Consequence for a batch: if the batch runs in the same run-loop pass as other edits, and `groupsByEvent` is `true`, the batch group is nested in the event group. The documentation does not say which action name the Edit menu then shows, or whether one Undo reverses the batch alone. Inference: a batch from an MCP request can share a pass with another edit. Test this case in the probe.

### Which action name a group shows

- `setActionName(_:)` "Sets the name of the action associated with the Undo or Redo command". An empty string removes the name [8].
- The archived guide: the name is appended to "Undo" and "Redo" "when the current undo group is at the top of the undo and redo stacks". "You should typically set the name at the same time as registering the operation to ensure that the two are kept in sync." [14]
- `undoActionName` returns an empty string when no name exists or nothing can be undone [9].
- `undoMenuItemTitle` returns "Undo" when no name is set, and `nil` when nothing can be undone [10].
- `undoMenuTitle(forUndoActionName:)` builds the title. Apple: "Override this method if you want to customize the localization behavior." `undoMenuItemTitle` calls it [11]. The archived guide says to localize the action name yourself [14].
- Apple does not say which name wins when `setActionName(_:)` runs several times in one group, or when an inner group and an outer group each set a name. No Apple page answers this. Sourced evidence only: GNUstep (an open reimplementation, not Apple code) stores the name on the open group with a plain assign, so the last call on that group wins. When a nested group closes, GNUstep moves its actions to the parent and does not copy its name (`endUndoGrouping`, lines 336 to 400) [17]. So the name of an outer batch group stays whatever was set on the outer group. Mark this as Inference for macOS.
- Apple HIG: "you can modify the menu item labels to identify the result. For example, a document-based app might use menu item labels like Undo Typing or Redo Bold." [18]

### A failure inside a group

- Apple documents no abort or rollback call for a group. `endUndoGrouping()` only closes it [3].
- `undoNestedGroup()` "Performs the undo operations in the last undo group (whether top-level or nested), recording the operations on the redo stack as a single group." Close the group first [7][15]. After this call a redo entry remains. Registering a new undo operation clears the redo stack [13]. Apple has no call that drops only the redo entry. Inference: a rollback by `undoNestedGroup()` leaves a redo entry until the next edit.
- `undo()` closes the top-level group when needed. It raises `NSInternalInconsistencyException` if more than one group is open [6]. Close every nested group before you call it.
- `removeAllActions(withTarget:)` "Clears the undo and redo stacks of all operations involving the specified target". It works on the whole stack, not on one group, so it does not roll back a batch. Apple uses it when a target is deallocated [12][16].
- `canUndo` true does not mean `undo()` is safe: "you may have to close open undo groups first" [37].
- Unity has the opposite pair for reference: `Undo.CollapseUndoOperations(group)` merges all steps down to a group into one, and `Undo.RevertAllDownToGroup(group)` reverts them "without storing a redo operation" [43]. AppKit has no such call.

## 2. How other apps name a grouped Undo step

Rule used here: if a page does not say it, the table says "silent". Nothing is guessed.

| App | What the user guide says | Grouped step or name |
|---|---|---|
| Logic Pro (Mac) | Edit > Undo, Redo, and an Undo History window with "a time-ordered list of all edits". Select an entry to undo the steps below it. Mixer and plug-in steps join the list through two buttons [19][20]. | Silent on how a multi-edit command is named or counted. Silent for Strip Silence: the page lists its parameters and a Replace dialog, and has no undo line [21]. |
| GarageBand (Mac) | "choose Edit > Undo (or press Command-Z)". "choose Edit > Redo (or press Shift-Command-Z)" [22]. | Silent. The page has four lines. |
| Final Cut Pro (Mac) | Undo reaches back to the last quit and reopen of the app [23][24]. The shortcut table names the commands "Undo Change" and "Redo Change" [23]. For Find and Replace Title Text: "choose Edit > Undo Text Replace (or press Command-Z)" [23]. | One menu name, "Undo Text Replace", covers the operation of the Find and Replace window. The same page lists a Replace All button. The page does not say that Replace All is one step. |
| Hindenburg PRO | Shortcut table: "Edit - Undo: Undo the last action"; "Edit - Redo: Recover any unintentional edits made in your session" [25]. | Silent on grouped steps, step names, and an undo history. The "Group" rows on that page are region groups, not undo groups. |
| Hindenburg Journalist (Mac) | Toolbar legend: "Undo > Undo last edit", "Redo > Redo last edit" [27]. | Silent. The host is a course handout that hosts Hindenburg's guide, not hindenburg.com. |
| Hindenburg release notes | PRO 2.02: "Enhanced the undo feature to restore the correct time when undoing word edits." "Fixed a crash related to undoing multiple text edits." [26] | Shows that word edits are undoable. Does not say that several edits form one step. |

What this means:

- No Logic Pro, GarageBand, or Hindenburg page defines how to name a grouped step. The planner has no manual rule to copy from them.
- Final Cut Pro shows one verb-plus-noun name for one command that changes many instances: "Undo Text Replace" [23]. The manual does not say the command is one step.
- The Apple HIG gives the naming rule for Mac apps: put the result in the menu label, for example "Undo Typing" [18]. It also says "Consider giving people the option to revert multiple changes at once" for "a batch of discrete but related actions" [18].
- I did not find a Hindenburg page that lists a batch of markers, a macro, or a group edit with undo. Marked in `## Open questions`.

## 3. MCP: protocol batching and real batch tools

### The specification

- 2025-03-26 changelog, major change 3: "Added support for JSON-RPC **batching** (PR #228)". The basic page: "MCP implementations **MAY** support sending JSON-RPC batches, but **MUST** support receiving JSON-RPC batches." [28][32]
- 2025-06-18 changelog, major change 1: "Remove support for JSON-RPC **batching** (PR #416)" [29]. The PR text gives the reason: no compelling use case, and "parallel tool calling ... is quite strait forward" [33].
- The 2025-06-18, 2025-11-25, and 2026-07-28 `basic` and `transports` pages have no "batch" text (checked with a text search). The 2025-11-25 and 2026-07-28 changelogs list no new batching entry [30][31].
- The spec defines no tool-level batch and no atomicity across tool calls. JSON-RPC 2.0 says a server "MAY process a batch rpc call as a set of concurrent tasks, processing them in any order", and responses "MAY be returned in any order" [34]. Protocol batching could never give one undo step.

### Real servers

All four were read at the commit shown in `## Sources`.

**A. Filesystem server `edit_file`** (modelcontextprotocol/servers) [38]
- Input: `path`, `edits` (array of `{oldText, newText}`), `dryRun`. No count limit in the schema.
- Atomicity: all or nothing per file. `applyFileEdits` applies the edits in memory in order. It throws on the first edit with no match and writes only after the loop. Code: `lib.ts` lines 494 to 572.
- Failure: the handler throws `Could not find exact match for edit:` plus the `oldText`. It gives no index of the failed edit. The SDK turns a thrown error into an `isError: true` result [42].
- Success: a text item with a git-style diff, and `structuredContent: { content: <diff> }`, with `outputSchema` `{ content: string }` (`server.ts` lines 461 to 484).
- Sibling `read_multiple_files` is the opposite: partial. A failed path becomes a line `<path>: Error - <message>` and the call still succeeds (`server.ts` lines 396 to 429).

**B. mcp-unity `batch_execute`** (CoderGamester/mcp-unity) [39]
- Input: `operations`: array of `{tool, params, id?}`, 1 to 100 items. Flags: `stopOnError` (default true) and `atomic` (default false).
- Atomicity: optional. With `atomic`, it calls `Undo.IncrementCurrentGroup()` and `Undo.SetCurrentGroupName("Batch Execute")`. On the first failure it calls `Undo.RevertAllDownToGroup(group)`. On full success it calls `Undo.CollapseUndoOperations(group)`. Without `atomic`, earlier operations stay.
- Success and failure result (C# side): `{ success, message, results[], summary{total, succeeded, failed, executed} }`. Each result is `{ index, id, success, result | error }`. The index of the failed item is in the result.
- On the MCP side (`batchExecuteTool.ts`): the text is the message, a summary line, and "Failed operations:" with `[id] error`. If it failed and `stopOnError` is true, the handler throws, so the SDK sends `isError: true`. If it failed and `stopOnError` is false, it returns a normal result. It has no `structuredContent`.
- It rejects a nested `batch_execute`.
- Limit: 100.

**C. Unity MCP `batch_execute`** (CoplayDev/unity-mcp) [40]
- Input: `commands`: list of `{tool, params}`; `fail_fast`, `parallel`, `max_parallelism`.
- Atomicity: none. The C# loop runs each command and keeps the earlier ones. There is no undo call in `BatchExecute.cs`.
- Result: `{ results: [{tool, callSucceeded, result | error}], callSuccessCount, callFailureCount, ... }`. Items have no `index`; the position in the array is the index. If any command failed, the C# code returns an error response that still carries the data.
- Docs and code disagree: the docs say "`fail_fast: true` (default)"; the C# code reads `failFast ?? false`.
- Limit: default 25, set in the editor, hard maximum 100. Over the limit: an error that names both numbers.

**D. REAPER MCP `batch_update_tracks`** (danishaft/reaper-mcp) [41]
- Input: `changes`: array of typed track changes (`TrackBatchChange`), 1 to 64, no duplicate `track_guid`.
- Atomicity: described as "Atomic batch mutation". It checks every item first (pydantic and a Lua preflight), then runs one REAPER undo block labeled `Batch update N tracks`. Every mutating command needs a non-empty `undo_label` (`command_execution.lua` lines 403 to 413, 674 to 680). The Lua code calls `Undo_EndBlock2` also when the handler failed (`pcall`), so the label is set on a partial change. The code shows no rollback after the preflight.
- Success: `{ ok: true, tracks, track_count, changes_applied, warnings }`.
- Failure: `{ ok: false, error: { code, message, details, recoverable, suggested_action }, warnings }`. The Python code validates each item alone, so the error has no index. The tool returns a dict, so the framework result is not `isError`. That last point is an inference from FastMCP behavior, not checked.

Also seen: BatchIt (ryanjoachim/mcp-batchit) is a proxy tool `batch_execute` with `operations` of `{tool, arguments}`, `stopOnError`, `maxConcurrent`, `timeoutMs`. Its README says that finished sub-operations plus the failed one are in the response, and the rest are skipped [44]. It has no rollback.

Pattern across A to D: the two servers that group an undo step name it with a count or a fixed label ("Batch update N tracks", "Batch Execute"). Atomic ones check first or revert on the first failure. Only B puts an `index` in the result.

## 4. MCP tool result: structuredContent, outputSchema, isError

- `structuredContent` and `outputSchema` came with spec 2025-06-18: "Add support for structured tool output" (PR #371) [29]. Section "Tools > Data Types > Structured Content" and "Output Schema" [35].
- 2025-06-18 text: structured content is "returned as a JSON object in the `structuredContent` field". "For backwards compatibility, a tool that returns structured content SHOULD also return the serialized JSON in a TextContent block." If an output schema exists: "Servers **MUST** provide structured results that conform to this schema." "Clients **SHOULD** validate structured results against this schema." [35]
- 2026-07-28 text: `structuredContent` may be "any JSON value"; `outputSchema` may use any JSON Schema 2020-12 keyword (SEP-2106). The text-block SHOULD stays [31][36]. Keep `structuredContent` a JSON object, so clients of the 2025-06-18 spec accept it.
- Errors, 2025-06-18 section "Error Handling": two kinds. "Protocol Errors" are JSON-RPC errors for unknown tools, invalid arguments, and server errors. "Tool Execution Errors" are "Reported in tool results with `isError: true`": API failures, invalid input data, business logic errors [35].
- 2026-07-28 text: tool execution errors "contain actionable feedback that language models can use to self-correct and retry". The example is `isError: true` with a `content` text item. "Clients **SHOULD** provide tool execution errors to language models to enable self-correction." [36]
- 2025-11-25 changelog: "input validation errors should be returned as Tool Execution Errors rather than Protocol Errors to enable model self-correction" (SEP-1303) [30].
- So `isError: true` with a text item is the spec way for a tool failure. The spec does not say that `structuredContent` must be absent when `isError` is true. The TypeScript SDK skips output validation when `result.isError` is true, and requires `structuredContent` otherwise when an `outputSchema` exists [42].
- 2026-07-28 examples also carry `"resultType": "complete"` in the result [36]. This is new in that version. It does not change the rules above.

## Open questions

1. Inference: the last `setActionName(_:)` call in a group wins on macOS. Source: GNUstep only [17]. Apple's pages are silent [8][14]. Not tested against: an inner group that names itself, then an outer group that names itself after `endUndoGrouping()`.
2. Inference: a batch group nested in the automatic event group shows its own name in the Edit menu only if it is alone in the run-loop pass. Not documented [2][4][13]. Most common gesture to check: an MCP call that arrives while the app also records a UI edit in the same pass.
3. Inference: `undoNestedGroup()` after a failed apply leaves a redo entry, and no Apple call removes it alone [7][13].
4. Probe source for 1 to 3 (not run, the brief forbids `swift`). Run later with `scripts/with-lock.sh scripts/probe.sh <folder> swift probe.swift`:
   ```swift
   import Foundation
   let um = UndoManager(); um.groupsByEvent = false
   final class T { var n = 0 }; let t = T()
   func edit(_ name: String) { um.registerUndo(withTarget: t) { $0.n -= 1 }; t.n += 1; um.setActionName(name) }
   um.beginUndoGrouping(); edit("A"); edit("B"); um.setActionName("Batch"); um.endUndoGrouping()
   print(um.undoMenuItemTitle)            // expected "Undo Batch" if last call wins
   um.beginUndoGrouping(); edit("C"); um.beginUndoGrouping(); edit("D"); um.endUndoGrouping(); um.endUndoGrouping()
   print(um.undoMenuItemTitle)            // inner name or outer name?
   um.beginUndoGrouping(); edit("E"); um.endUndoGrouping(); um.undoNestedGroup()
   print(um.canRedo, um.redoMenuItemTitle) // redo entry after rollback?
   ```
   Repeat with `groupsByEvent = true` inside a run-loop pass.
5. No source for Logic Pro, GarageBand, or Hindenburg on the name of a grouped step, on a marker batch, or on a macro. The Hindenburg shortcut table showed no rows in a plain download. The rows quoted above came from a page-fetch tool, which showed Windows keys (Ctrl Z) [25]. Only those rows were seen.
6. Final Cut Pro: the manual does not say that Replace All is one undo step [23].
7. Unity MCP (CoplayDev): whether an error response with data becomes `isError: true` in the client. The Python proxy returns a dict, and the code between was not traced [40].
8. REAPER MCP: the "no index" and "not `isError`" claims are from reading the Python code, not from running the server [41].
9. Inference: the default name "Batch (N edits)" and the cap of 100 are choices from the pattern in section 3, not from a rule in any source.

## Sources

1. https://developer.apple.com/documentation/foundation/undomanager (append `.md` for plain text) - class overview, topic list, MainActor note.
2. https://developer.apple.com/documentation/foundation/undomanager/beginundogrouping() - begin, nesting, event-loop default.
3. https://developer.apple.com/documentation/foundation/undomanager/endundogrouping() - group semantics, "nested transactions", exception.
4. https://developer.apple.com/documentation/foundation/undomanager/groupsbyevent - default true, close groups yourself when false.
5. https://developer.apple.com/documentation/foundation/undomanager/groupinglevel - nesting count.
6. https://developer.apple.com/documentation/foundation/undomanager/undo() - closes the top-level group, exception for more than one open group.
7. https://developer.apple.com/documentation/foundation/undomanager/undonestedgroup() - undo of the last group, one redo group.
8. https://developer.apple.com/documentation/foundation/undomanager/setactionname(_:)-8lzip and https://developer.apple.com/documentation/foundation/undomanager/setactionname(_:)-cci9 - action name, empty string clears.
9. https://developer.apple.com/documentation/foundation/undomanager/undoactionname - returned value.
10. https://developer.apple.com/documentation/foundation/undomanager/undomenuitemtitle - "Undo" or nil.
11. https://developer.apple.com/documentation/foundation/undomanager/undomenutitle(forundoactionname:) - override for localization.
12. https://developer.apple.com/documentation/foundation/undomanager/removeallactions(withtarget:) - clears whole stacks for a target.
13. https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/UndoArchitecture/Articles/UndoManager.html - groups, run-loop grouping, redo stack cleared by a new operation.
14. https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/UndoArchitecture/Articles/SettingUndoNames.html - action names, "top of the undo and redo stacks".
15. https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/UndoArchitecture/Articles/PerformingUndo.html - `undo` versus `undoNestedGroup`.
16. https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/UndoArchitecture/Articles/CleaningUndoStack.html - `removeAllActions(withTarget:)` use.
17. https://github.com/gnustep/libs-base/blob/79f9b83c96e5a584744786c2531119fa30211f36/Source/NSUndoManager.m - GNUstep reimplementation: `setActionName:` at line 851, group method at line 142. Secondary evidence, not Apple code.
18. https://developer.apple.com/design/human-interface-guidelines/undo-and-redo - menu label naming, revert a batch.
19. https://support.apple.com/guide/logicpro/undo-and-redo-edits-lgcp1dbd67ab/mac - Logic Pro for Mac 12.3 undo and Undo History.
20. https://support.apple.com/en-gb/101876 - Logic Pro Mixer and plug-in undo.
21. https://help.apple.com/logicpro/mac/10.1/en.lproj/lgcp86ee7672.html - Strip Silence window (Logic Pro 10.1 page, no undo text).
22. https://support.apple.com/guide/garageband/gbnd674b44b9/mac - GarageBand for Mac undo and redo.
23. https://help.apple.com/pdf/final-cut-pro/en_US/final-cut-pro-user-guide.pdf - Final Cut Pro for Mac guide, sections "Save and back up projects", "Find and replace text", and the shortcut table. Text extracted from the downloaded PDF.
24. https://support.apple.com/guide/final-cut-pro/save-and-back-up-projects-ver79aa3d71/mac - undo reach.
25. https://hindenburg.com/academy/shortcuts/shortcuts-hindenburg-2-pro/ - Undo and Redo rows.
26. https://hindenburg.com/release-notes-hindenburg-pro_version-2/pro-v2_02-build-2572/ - undo fixes.
27. https://www.willyurman.com/teaching/handouts/Hindenburg_Journalist.pdf - Hindenburg Journalist PRO user guide (Mac), hosted by a third party.
28. https://modelcontextprotocol.io/specification/2025-03-26/changelog - batching added (PR #228).
29. https://modelcontextprotocol.io/specification/2025-06-18/changelog - batching removed (PR #416), structured tool output added (PR #371).
30. https://modelcontextprotocol.io/specification/2025-11-25/changelog - SEP-1303 input validation errors.
31. https://modelcontextprotocol.io/specification/2026-07-28/changelog - SEP-2106 schema and `structuredContent` change; no batching entry.
32. https://modelcontextprotocol.io/specification/2025-03-26/basic/index.md - "Batching" section.
33. https://github.com/modelcontextprotocol/modelcontextprotocol/pull/416 - reason for the removal.
34. https://www.jsonrpc.org/specification - section 6 Batch.
35. https://modelcontextprotocol.io/specification/2025-06-18/server/tools.md - Structured Content, Output Schema, Error Handling.
36. https://modelcontextprotocol.io/specification/2026-07-28/server/tools.md - same sections, newest version.
37. https://developer.apple.com/documentation/foundation/undomanager/canundo - `canUndo` does not mean `undo()` is safe while a group is open.
38. https://github.com/modelcontextprotocol/servers/tree/ef9808f71090d0db3eda99e2af2ba78f1086f4fb/src/filesystem - `server.ts`, `lib.ts` (`edit_file`, `read_multiple_files`).
39. https://github.com/CoderGamester/mcp-unity/tree/d572dc88f1b982a0fdfc09cd14cfdfd760b658e8 - `Editor/Tools/BatchExecuteTool.cs`, `Server~/src/tools/batchExecuteTool.ts`.
40. https://github.com/CoplayDev/unity-mcp/tree/ed4e205d31a545bac3686d5e19210e67959aeddd - `Server/src/services/tools/batch_execute.py`, `MCPForUnity/Editor/Tools/BatchExecute.cs`, `website/docs/reference/tools/core/batch_execute.md`.
41. https://github.com/danishaft/reaper-mcp/tree/b4c0487010ff5d5033ce37484da6a56b9c6a8f27 - `src/reaper_mcp/services/batch_service.py`, `src/reaper_mcp/tools/batch.py`, `lua/reaper_mcp_bridge_modules/command_execution.lua`; README "Every write is validated before execution and appears as one named REAPER undo step."
42. https://github.com/modelcontextprotocol/typescript-sdk/blob/b415e60bdf0e8dd5d6cbe7e6353abfb982b06dd2/packages/server/src/server/mcp.ts - `createToolError` (line 333), `validateToolOutput` (line 385).
43. https://docs.unity3d.com/ScriptReference/Undo.CollapseUndoOperations.html, https://docs.unity3d.com/ScriptReference/Undo.RevertAllDownToGroup.html, https://docs.unity3d.com/ScriptReference/Undo.SetCurrentGroupName.html - Unity group API.
44. https://github.com/ryanjoachim/mcp-batchit/blob/5870243813342a77c96c478468e821d4260d470e/README.md - proxy batch, `stopOnError`, partial results.
