# 0021. Recovery tools: the take anchor file, the placement of one segment, and a finish without unreadable audio

- Status: accepted
- Date: 2026-09-26
- Amended: 2026-09-27. The anchor magic is a 7-byte prefix and a version digit. A newer anchor is a per-segment fault at a placement that needs it. A finalize keeps a newer anchor and ends the take; an anchor that does not read keeps the take pending before any WAV. The anchor name counts for the next take number (see 0024).
- Amended: 2026-10-04, run 12. A split take, an unplaced segment with a placed segment of the same take, blocks each ripple until the segment is placed; a wholly unplaced take does not (see 0037).
- Amended: 2026-10-12, run `2026-10-12-remove-unused-files` (see 0047). The WAV that an undo of a placement leaves in `Clips/` is a stray WAV. Remove Unused Files can move it to the Trash, unless a clip of an undo or redo entry, of a backup, or of `session.xml` uses it. A later placement writes it again from the CAF.
- Amended: 2026-11-03, run `2026-10-28-pre-roll` (see 0004). A placement at the recorded time has the floor of 0004 **Timing**; a segment with no frame after it is a pool file with no clip, not a fault.
- Amended: 2026-10-22, run `2026-10-22-take-sync` (see 0061). The take map is a second reader of the anchor files: they keep the take time, so they must stay. `TakeAnchors.read` reads each anchor of `Capture/`; an errno other than ENOENT on `Capture/` throws, and on an anchor it is the fault of that take only.

## Context

Decision 0012 leaves a segment unplaced when finalize cannot place it, and names a later command that places one unplaced stem through the same per-segment finalize. Two facts block that command and one fact blocks a take:

- The per-segment finalize takes the track (`recording.armedTracks[arm - 1]`) and the aligned start (`recording.playheadFrame`, `recording.takeStartHostTimeNanos`) from `<recording>`. The save at the end of the take removes `<recording>`. After it, the session has no arm-to-track map and no take anchor. The sidecar has the host time of the segment, not the anchor.
- `Session.addFile` has no rule for two pool files with one path. The take number rule of 0012 counts IDs, not paths. So a pool file that a user added with the path `take5-1-1.wav` before take 5 is overwritten by the finalize of take 5. A placement has the same risk.
- 0012 keeps a take pending on a read errno other than ENOENT on a segment file, so a retry can succeed. A bad sector gives the same errno on every retry. The take then stays pending for ever: its armed tracks keep their route and layout, and no new take starts. The only way out is to delete the CAF by hand.

Hindenburg research (`docs/research/recovery-tools.md`): Hindenburg documents crash recovery (PRO 2 build 2610), relink of missing files, and import by hand. It documents no tool that puts an unplaced recording back at its recorded time. REAPER and Logic show unused files only to delete them.

The run design is in `.scratchpads/runs/2026-09-26-recovery-tools/design.md`. It compares three places for the anchor (below).

## Decision

**The take anchor file.** Each finalize that ends a take (stop, recovery at open, retry, `dirigible take finalize`) writes `Capture/take<n>.anchor` after the WAVs and `Clips/` are flushed and before the save that removes `<recording>`. The file holds the `Recording` of the take: the take number, the playhead frame, the take start host time, and the armed track IDs in arm order.

- Bytes: the record framing of the sidecar (0012). An 8-byte magic `DRGANCH1`, then one record: a UInt32 payload length, the kind 1, the payload, and the FNV-1a 32-bit hash. The payload is the take (UInt32), the playhead frame (Int64), the take start host time in nanoseconds (UInt64), a UInt32 track count, and each track ID (a UInt32 byte count and UTF-8). Little-endian. The counts are UInt32 because `Session` does not limit the length of a track ID. A pre-roll take writes the magic `DRGANCH2` and adds a UInt8 pre-roll flag 1 after the track IDs (0024).
- The reader refuses a bad magic, a short record, a bad hash, bytes after the record, a take outside `Recording.takes`, a negative playhead, a track ID that `Session` does not store, and a take number that is not the number in the file name. A refused file is the same as no file. A newer anchor is a per-segment fault at placement; a finalize keeps it and ends the take (0024). ENOENT is no file. Another errno on the open or the read throws `FinalizeError.readFailed(file: "Capture/take<n>.anchor", errno:)`, as the sidecar read does, so a fault that can go away is not taken for a missing anchor.
- The write runs under the package lock. It unlinks a leftover `Capture/.take<n>.anchor.tmp` of a crashed write, opens that name with `O_CREAT | O_TRUNC` (never `O_EXCL`, so a leftover cannot keep a take pending), writes, flushes, renames it to `take<n>.anchor`, and then flushes `Capture/`. A write, flush, or rename fault is `FinalizeError.writeFailed(file: "Capture/take<n>.anchor", status:)`: the take stays pending, and a retry can succeed (the class of a `Clips/` fault in 0012).
- A crash after the rename and before the save leaves `<recording>`. The recovery writes the same bytes again.
- No tool deletes an anchor file. The name counts for the next take number, so a take with no segment does not give its number to the next take (0024 P10).

**Placement of one segment.** `Studio.place(_ segment: SegmentName, on track: TrackID? = nil, at start: Frames? = nil) async throws(StudioError) -> ClipID`.

- `SegmentName` becomes public. The CLI parses a stem with it at the boundary.
- The segment must be in `Studio.unplacedSegments`, which becomes `[SegmentName]`. So a segment of the pending take, a placed segment, and a stem with no CAF are refused before any file I/O.
- With no track and no start, the segment goes where the finalize of its take would have put it: the track of its arm and the aligned start, from the anchor file. A given track replaces the anchor track. A given start puts the first frame of the WAV at that frame (offset 0). With no anchor file, the call needs both. A negative start throws `.segment(s, .session(.frameOutOfRange))` before any file I/O: only an aligned start moves its negative part into the file offset.
- It first ends a running play, as a take start does (`endPlayForTake`, then the Player stop), so no play reads the session while it changes.
- Before the CAF opens, it resolves the target into one of two cases: `aligned(Recording, track:)` (the anchor, with the given track or the track of the arm) or `fixed(track:, start:)`. An arm outside the armed tracks of the anchor, or a missing track or start with no anchor, throws `.segment(s, .noAlignment)`.
- After the sidecar read and before the conversion, the per-segment finalize checks the target track: a track that is not in the session throws `.segment(s, .session(.unknownTrack))`, and a track whose layout does not match the channel count of the sidecar throws `.segment(s, .session(.layoutMismatch))`. So a bad target converts nothing.
- It refuses with `StudioError.placementSpace(needed:free:)` when the free space of the volume is less than 3/4 of the CAF bytes of the segment plus the 1 GB margin of 0004 (the rule of the pending take). `needed` is that sum and `free` is the free space, so the app and the CLI show the rule of the placement, not the 1 GB rule of a take start.
- It runs the per-segment finalize of 0012 (the sidecar, the rate choice, the conversion, the flush, the length read-back), flushes `Clips/`, and saves under the lock, in the write chain, off the main actor. The transport is `.placing(SegmentName)` until it ends, so an edit, an undo, a take, a retry, a play, and an export throw `.busy`.
- The per-segment finalize, for a placement and for a take finalize, writes the WAV to `Clips/.<stem>.wav.tmp` and renames it to `<stem>.wav` only after the length read-back and after the session accepts the capture, the file, and the clip. A throw or a segment fault unlinks the temporary file. So a full disk, a write fault, or a refusal leaves no partial or unused `<stem>.wav`.
- A success is one undo entry. An undo makes the segment unplaced again. The WAV stays. A placement is a new edit, so it clears the redo stack. An undo past a take makes every segment of the take unplaced, and a redo brings them back; so the app disables its Place action while Redo is available. The library and the CLI do not refuse (the CLI has no history).
- The clip goes on top of the clips under it, as a paste and as the finalize do.
- A refusal throws `StudioError.segment(SegmentName, SegmentFault)` and changes nothing in the session. `SegmentFault` is `notUnplaced`, `noSidecar`, `badAudio`, `noAlignment`, `wavInUse(FileID)`, or `session(SessionError)`. A segment with no frame after the take playhead (the floor of 0004 **Timing**) is no refusal: `Studio.place` adds a pool file with no clip and returns nil, and `dirigible capture place` prints `no clip: the segment ends before the take playhead`. A fault that can go away throws `.finalize` or `.file`, as a finalize does.

**The WAV guard.** Before the per-segment finalize writes `Clips/<stem>.wav`, it refuses when a pool file of the session has that path or the temporary path `.<stem>.wav.tmp`, compared after the removal of `.` components and without case. In a take finalize the segment then stays unplaced (a segment fault of 0012), and the file of the user stays unchanged. In a placement it is `.wavInUse(id)`.

**Finish without unreadable audio.** `Studio.retryFinalize(leavingUnreadable: Bool = false)` and `dirigible take finalize --leave-unreadable`.

- `FinalizeError` gets the case `segmentUnreadable(SegmentName, file: String, errno: Int32)`. It is an errno other than ENOENT on the open or a read of the CAF or the sidecar of one segment (also the errno that `ioErrno` finds under an `AVAudioFile` error), which was `readFailed` before this decision. It stays take-wide by default: the stop, the recovery at open, a plain retry, and a plain `take finalize` keep the take pending, as 0012 says.
- With `leavingUnreadable: true`, that segment stays unplaced and the finalize goes on to the next segment. The take ends. The segment files stay in `Capture/`, and the anchor file is written, so a later placement can put the segment at its recorded time.
- These faults stay take-wide in both modes: `Capture/` missing or unreadable, a listed CAF that is gone (ENOENT: the package moved, 0014), and every `Clips/`, WAV, and anchor write, flush, close, rename, or read-back fault. Free space or access fixes them, and a finish without them would push every segment off the timeline.
- Only a user action sets the flag. No count of failed retries sets it.
- A placement of a segment that does not read throws `.finalize(.segmentUnreadable)` and changes nothing.

**CLI (0011).**

- `dirigible capture place <package> <segment> [--track <id>] [--at <frame>]` writes the clip ID on stdout. Exit 0 on success. Exit 1 when the placement is refused (a `SegmentFault`, or less free space than the placement needs), with one line `Error: <message>`; the package does not change. Exit 2 for a package fault: a pending take (checked before `Studio.open`, as `record` does), a held lock, or a read or write fault (also an anchor file that does not read). Exit 64 for a stem that does not parse or a negative `--at`.
- `dirigible take finalize --leave-unreadable` retries the pending take in that mode, then reports as `take finalize` does (0013): the clip IDs, one warning line for each unplaced segment, and exit 3. Without the flag, a `segmentUnreadable` error ends with ` Run it again with --leave-unreadable to finish without that segment.` and exit 2.

**App (0014).** The take banner shows one row for each unplaced segment, in a list that shows at most 4 rows and scrolls. Each row has the stem and a Place menu: its primary action places the segment at its recorded track and time, and the item "Place at Playhead on Selected Track" needs exactly one selected track. While Redo is available, the rows are disabled and a hint says that Redo brings the audio back. A pending take whose error is `segmentUnreadable` shows a hint and the button "Finish Without Unreadable Audio" beside Retry; another take error does not show it. During a placement the banner shows "Placing <stem>…". A refusal shows the error alert. A segment with no anchor file (a take made before this decision) cannot use the primary action, so its alert names "Place at Playhead on Selected Track". The strings are in each language of 0010.

## Consequences

- 0012 gets an amended line: the anchor file, the WAV guard, `segmentUnreadable`, and the leave mode. The rule "a read errno keeps the take pending" keeps its owner on every path that the user did not choose.
- 0004 does not change: the start order does not write the anchor.
- `StudioError`, `FinalizeError`, and `Studio.Transport` get cases. Each switch with no `default` (the CLI message, `L10n.message`, the take banner) gets its line.
- A segment of a take that ended before this decision has no anchor file. Its placement needs `--track` and `--at`.
- A segment with a missing or refused sidecar cannot be placed (`noSidecar`). A placement from the CAF format alone needs a capture with unknown timing; it is in the backlog.
- A pending take with an unreadable segment is converted again at every open until the user chooses the leave mode.

## Alternatives considered

- **The anchor in a sidecar version 2, written by the segment writer.** Each segment then carries its own anchor, also for a take that never finalizes. Rejected: it changes the sidecar format and the writer plumbing of the live capture (`TakeFiles`, `TrackSegments`) for a fact that `<recording>` already holds until the end of the take. The anchor is needed only after that end.
- **The anchor file written at the take start, before the save of `<recording>`.** Rejected: it adds one flushed write to the 0004 start order and a new crash case before the take exists, for no gain over a write at the end.
- **A `<take>` element in `session.xml`.** Rejected: 0003 raises the version for a new element, and undo would need a rule for it.
- **The aligned start from a placed segment of the same take (start minus offset).** Rejected: a move changes it, and a track with one segment has no such segment.
- **The caller always gives the track and the start.** Rejected as the only form: a CLI user cannot compute the drift and latency terms. It stays as the override.
- **An `.abandoned` marker file per segment.** Rejected: it adds a second marker convention to the package. The leave mode needs no stored state, because its save ends the take.
- **Leave only the named segment.** Rejected: two bad segments would need two retries of minutes each. The report lists each segment that stays unplaced.
