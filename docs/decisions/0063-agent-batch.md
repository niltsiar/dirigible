# 0063. Agent batch: many edit calls as one undo step

- Status: accepted
- Date: 2026-10-26
- Accepted: 2026-10-26, after plan gate 1 of run `2026-10-26-agent-batch`.
- Amends: 0002 (Snapshot undo: one entry for a batch), 0011 (Grammar: `batch` applies many edits in one save; the command and its exit codes), 0041 (the tool `batch`), 0046 (Live tools), 0037 (the ripple rule of each step)

## Context

An agent call is one undo step in the app and one read-edit-save on the files (0041, 0046). The tester agent made about 60 edits one by one (tester report 2026-10-16, section 6). `History.edit` runs its body on a copy, discards the copy on a throw, and records one entry when the session changed. `editPackageCore` writes only after its body returns. `rippleBlocked` reads the session value: a `file_remove` can split a take.

Agents and scripts compare the tool and CLI text (0011, 0041), so the call shape and the result text are a contract. Each tool gives one text item. Each tool maps to a CLI command (`ParityTests.everyCommandHasATool`).

Research: `docs/research/undo-grouping.md`.

## Decision: the nested edit

- **One body for many steps.** A batch runs its steps in order inside one body: one `History.edit` in the app, one `editPackageCore` on the files. History does not change.
- **All or nothing.** A step that throws ends the body. The app discards the copy: no entry, no revision change, no save. The files path does not write: `session.xml` and `Backups/` stay. No step can write a file, because a step is a pure session edit (`(inout Session) throws -> [String]`), so there is nothing else to roll back.
- **One edit core in Studio.** `Studio.edit(agent:refused:_:)` is generic over the error of its body: `checkIdle`, one `History.edit`, one autosave, one pool change. `Studio.edit(ripple:agent:_:)` calls it, with the ripple check first in its body, so the order (busy, then `rippleBlocked`, then the body) stays.
- **Busy once, ripple for each step.** The busy cause and `checkIdle` run once, before the first step: the batch runs on the main actor with no suspension point, so no take, drag, sheet, or other call starts between two steps. The ripple rule runs before each ripple step on the working copy (`Studio.canRipple(_:)` in the app, `rippleBlocked(in:session:)` on the files), so a batch refuses a ripple where the same calls one by one refuse it.
- **Pending take.** In the app, a non-ripple step runs under a pending take, as one call does (0046), and a ripple step is refused at its index. On the files, a pending take refuses the whole batch before any step, as `editPackageCore` refuses any edit.
- **Notes and names.** The take sync note comes once, for the whole batch. The undo entry has the agent of the call, so the Undo and Redo items show the agent title of one edit (`undo.agent`).

## Decision: the call, the result, and the command

- **Call.** `batch` takes `package` and `calls`: an array of 1 to 20 objects `{"tool": <name>, "arguments": {...}}`. An inner call has no `package`: the batch gives it. Each inner call is checked as the call alone, on the listener queue in the app.
- **Steps.** A step is a call whose work changes only `session.xml` after its make. Each tool names its batch role at its definition (`batch: .step` or `.alone`, as `saves:`), and a test compares each tool with the step list. A `.step` tool is a step when its call copies no file: `marker_set` with no or an empty `image`, `episode_set` with no or an empty `artwork`, and `clip_paste` and `clip_paste_clips` with no `source` (an empty value clears the field, so it is a pure edit). An `.alone` tool, a `.step` call that copies a file, and `batch` are refused at check time: `<tool> cannot run in a batch: a step is an edit of session.xml only.` (for `batch`: `a batch cannot hold a batch.`). An `.alone` tool is refused before its make, so `chapters_import` and `transcript_import` read no file at check time.
- **New IDs.** To name a new object in a later step of the same batch, the earlier step gives its ID: `track_add` `id`, `track_add_call` `host_id` and `guest_id`, `clip_place` `id`, `clip_split` `right_id`, and `marker_set` `id`. A tool with no ID argument, for example `clip_split_at` or `clip_paste`, gives its new IDs in its result lines. A batch has no reference to the result of an earlier call (later item 1066).
- **Index.** `calls[<i>]`, from 0, as the JSON array.
- **Success text.** One line `calls[<i>] <tool>: <line>` for each result line of each call (a new ID, or `OK`), in call order, then the take sync note lines once.
- **Failure text.** `isError: true` and one line `calls[<i>] <tool> failed, so the batch changed nothing: <text>`, where `<text>` is the text of that call alone. It is the same for a check failure and a step failure. The count gives `The argument "calls" must be an array of 1 to 20 calls.` A busy cause and a pending take on the files give their text with no index, because no call ran: the batch failure type holds only the causes of one call, and the app gives a busy studio its existing busy text.
- **Count limit.** 1 to 20. A live batch runs all its steps in one main-actor turn, where single calls give the run loop a turn between calls, so one batch at the limit must hold the main actor under 250 ms. Probe P3 (6 tracks of 201 clips, the round trip through the agent socket): 100 calls of `clip_gain_range` took 3462 ms, so the limit is the largest count under 250 ms of that step, 20 calls (224 ms; 21 calls took 257 ms). The tester's about 60 edits are 3 batches.
- **CLI.** `dirigible batch <package> <file|->` reads the `calls` array from a file or stdin with the argument parse and the `calls` Kind of the tool, so the item shape and the count text are the same, runs the same check and the one files entry of the tool, and writes the success lines to stdout. Exit 0; 64 for a JSON, count, or check failure; 1 for a refused step; 3 for a ripple step on a split take; 2 for a locked package, a pending take, or a read or write fault (0011 table). `batch` maps to `batch` by the name rule, so no parity exception.
- **Undo title.** No new UI string: the step shows the agent title of one edit.

## Consequences

- One undo restores the session before the batch; one redo applies the whole batch again.
- A user edit or another agent call never lands between two steps.
- A batch cannot hold work that writes or reads files (import, level, duck, split, paste from another package, image, artwork, backup revert, chapters and transcript import). Each such call stays one undo step alone.
- An agent maps each new ID to its call by the index.
- One live batch of 20 calls of `clip_gain_range` on a session of 6 tracks of 201 clips takes 224 ms (round trip, minimum of 3 runs; probe P3). The cost of `clip_gain_range` grows with the calls on the same clips (100 calls: 3462 ms), so the limit is a count and not a time bound. Other steps are faster: 100 calls of `clip_ripple_insert` took 264 to 277 ms.
- A new tool names its batch role, and the role test fails until the step list or the alone list names it.
- A change of the line form is a breaking change for agents and scripts and needs a note in the pull request (0011).

## Alternatives considered

- **History grouping** (`beginGroup`, `endGroup`, `abandonGroup`, as NSUndoManager groups): rejected. A group stays open across a throw, each call schedules its own save and pool change, and the files path still needs one body, so it gives two ways to do one task.
- **One ripple check before the batch:** rejected. A `file_remove` step can split a take, and a later ripple step then moves a split take (0037).
- **structuredContent with an outputSchema:** deferred. No tool of Dirigible has one, and text keeps one rule for all tools.
- **A parity exception** (a tool with no command): rejected. `ParityTests` refuses it, and scripts get the one-save edit from the command.
- **A batch Undo title** ("Undo <name> Edits"): deferred to a later run with the UI panel and seven tables (0010).
